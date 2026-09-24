import AppKit
import AVFoundation
import CoreFoundation
import Foundation

/// macOS 26 (Tahoe) lock-screen video installer.
///
/// Tahoe stores downloaded Apple Aerial movies in the current user's home folder.
/// There is no public API for arbitrary lock-screen videos, so this installer uses
/// the native Aerial pipeline: it converts the selected movie to a video-only MOV,
/// backs up one downloaded Apple Aerial, swaps our movie into that slot, points the
/// Wallpaper store at that Aerial asset, and configures the screen saver to use the
/// system WallpaperAerialsExtension.
final class MacOS26LockScreenInstaller {
    struct ResultInfo {
        let sourceURL: URL
        let slotURL: URL
        let backupURL: URL
        let reportURL: URL
        let firstInstall: Bool
    }

    enum InstallError: LocalizedError {
        case unsupportedSystem
        case noSelectedVideo
        case videoNeedsConversion
        case noDownloadedAerial
        case wallpaperStoreMissing
        case noVideoTrack
        case videoTooShort
        case exportUnavailable

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem:
                return "Motion Wallpaper requires macOS 26 (Tahoe) or later."
            case .noSelectedVideo:
                return "No lock-screen video is selected."
            case .videoNeedsConversion:
                return "Convert this video for macOS 27 before installing it on the lock screen."
            case .noDownloadedAerial:
                return "No downloaded Apple Aerial was found. Open System Settings → Wallpaper, download any animated Aerial once, then try again."
            case .wallpaperStoreMissing:
                return "The macOS Wallpaper store is not initialized yet. Open System Settings → Wallpaper once, choose an Apple Aerial, and try again."
            case .noVideoTrack:
                return "The selected file has no readable video track."
            case .videoTooShort:
                return "The selected video is too short."
            case .exportUnavailable:
                return "macOS could not prepare this video for the Aerial renderer. Try an MP4/MOV encoded as H.264 or HEVC."
            }
        }
    }

    private struct State: Codable {
        let slotFileName: String
        let installedAt: Date
    }

    private static let fm = FileManager.default
    private static let minimumMajorVersion = 26
    private static let targetDurationSeconds = 180.0

    private static var home: URL { fm.homeDirectoryForCurrentUser }

    private static var aerialsRoot: URL {
        home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    }

    private static var aerialVideosDirectory: URL {
        aerialsRoot.appendingPathComponent("videos", isDirectory: true)
    }

    private static var wallpaperStoreURL: URL {
        home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    private static var backupDirectory: URL {
        WallpaperStore.shared.appSupportDirectory.appendingPathComponent("MacOS26LockScreen/Backups", isDirectory: true)
    }

    private static var stateURL: URL {
        WallpaperStore.shared.appSupportDirectory.appendingPathComponent("MacOS26LockScreen/state.json")
    }

    private static var originalStateDirectory: URL {
        WallpaperStore.shared.appSupportDirectory.appendingPathComponent("OriginalSystemWallpaper", isDirectory: true)
    }

    private static var wallpaperStoreBackupURL: URL {
        originalStateDirectory.appendingPathComponent("Index.plist")
    }

    private static var lockScreenPosterBackupURL: URL {
        originalStateDirectory.appendingPathComponent("lockscreen.png")
    }

    private static var noLockScreenPosterMarkerURL: URL {
        originalStateDirectory.appendingPathComponent("no-lockscreen-poster")
    }

    private static var screenSaverModuleBackupURL: URL {
        originalStateDirectory.appendingPathComponent("screensaver-module.plist")
    }

    private static var noScreenSaverModuleMarkerURL: URL {
        originalStateDirectory.appendingPathComponent("no-screensaver-module")
    }

    static var reportURL: URL {
        WallpaperStore.shared.appSupportDirectory.appendingPathComponent("macos26-lock-screen-install-report.json")
    }

    static var isSupportedRuntime: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= minimumMajorVersion
    }

    static var isInstalled: Bool {
        guard let state = loadState() else { return false }
        let slot = aerialVideosDirectory.appendingPathComponent(state.slotFileName)
        return fm.fileExists(atPath: slot.path) && fm.fileExists(atPath: backupURL(for: slot).path)
    }

    /// True when Motion Wallpaper has enough saved state to offer a restore action.
    /// This intentionally also covers interrupted/partial installs where the Aerial
    /// swap state file was not written but the native Wallpaper store snapshot exists.
    static var hasRestorableState: Bool {
        loadState() != nil || fm.fileExists(atPath: wallpaperStoreBackupURL.path)
    }

    @discardableResult
    static func installSelectedVideo(progress: @escaping (Double) -> Void = { _ in }) async throws -> ResultInfo {
        try requireMacOS26()
        let store = WallpaperStore.shared
        guard let item = store.item(id: store.loadSettings().lockScreenVideoID) else {
            throw InstallError.noSelectedVideo
        }
        return try await install(videoURL: store.url(for: item),
                                 preparedURL: store.preparedURL(for: item), progress: progress)
    }

    static func prepare(item: VideoItem, progress: @escaping (Double) -> Void = { _ in }) async throws {
        let store = WallpaperStore.shared
        if store.isPreparedForLockScreen(item) { progress(1); return }
        let encoded = try await AerialTemporalEncoder.encode(
            source: store.url(for: item),
            progress: { progress($0 * 0.99) }
        )
        defer { try? fm.removeItem(at: encoded) }
        try Task.checkCancellation()
        try fm.createDirectory(at: store.preparedVideosDirectory, withIntermediateDirectories: true)
        let destination = store.preparedURL(for: item)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(item.id.uuidString)-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: staging) }
        try fm.moveItem(at: encoded, to: staging)
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: destination)
        progress(1)
    }

    @discardableResult
    static func install(videoURL source: URL, preparedURL: URL? = nil,
                        progress: @escaping (Double) -> Void = { _ in }) async throws -> ResultInfo {
        try requireMacOS26()
        try WallpaperStore.shared.ensureDirectories()

        let slot = try findAerialSlot()
        guard fm.fileExists(atPath: wallpaperStoreURL.path) else {
            throw InstallError.wallpaperStoreMissing
        }
        let backup = backupURL(for: slot)
        let firstInstall = !fm.fileExists(atPath: backup.path)

        // Capture the user's native wallpaper configuration before the first change.
        // This lets Restore return the desktop and lock screen to the exact state that
        // existed before Motion Wallpaper touched the Tahoe wallpaper store.
        try captureOriginalSystemWallpaperStateIfNeeded()

        let isMacOS27 = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        let converted: URL
        if isMacOS27 {
            guard let preparedURL, fm.fileExists(atPath: preparedURL.path) else {
                throw InstallError.videoNeedsConversion
            }
            converted = preparedURL
            progress(1)
        } else {
            do {
                converted = try await exportAerialMovie(source: source, preset: AVAssetExportPresetPassthrough)
            } catch {
                converted = try await exportAerialMovie(source: source, preset: AVAssetExportPresetHEVCHighestQuality)
            }
        }
        defer { if !isMacOS27 { try? fm.removeItem(at: converted) } }
        try Task.checkCancellation()

        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        if firstInstall {
            try fm.copyItem(at: slot, to: backup)
        }

        let replacement = slot.deletingLastPathComponent().appendingPathComponent(".motionwallpaper-\(UUID().uuidString).mov")
        try? fm.removeItem(at: replacement)
        defer { try? fm.removeItem(at: replacement) }
        try fm.copyItem(at: converted, to: replacement)
        try Task.checkCancellation()
        _ = try fm.replaceItemAt(slot, withItemAt: replacement)

        let assetID = slot.deletingPathExtension().lastPathComponent
        try selectAerialAsset(assetID: assetID)
        configureScreenSaverForAerials()
        await refreshLockScreenPoster(from: source)
        clearWallpaperCaches()
        reloadWallpaperRenderer()

        try saveState(State(slotFileName: slot.lastPathComponent, installedAt: Date()))
        try writeReport(source: source, slot: slot, backup: backup, assetID: assetID, firstInstall: firstInstall)

        return ResultInfo(
            sourceURL: source,
            slotURL: slot,
            backupURL: backup,
            reportURL: reportURL,
            firstInstall: firstInstall
        )
    }

    /// Restores the Apple Aerial file and the user's native wallpaper store that were
    /// captured before Motion Wallpaper made its first lock-screen change.
    static func restoreOriginalAerial() throws {
        try requireMacOS26()

        let state = loadState()
        let hasWallpaperSnapshot = fm.fileExists(atPath: wallpaperStoreBackupURL.path)
        guard state != nil || hasWallpaperSnapshot else { return }

        if let state {
            let slot = aerialVideosDirectory.appendingPathComponent(state.slotFileName)
            let backup = backupURL(for: slot)
            if fm.fileExists(atPath: backup.path), fm.fileExists(atPath: slot.path) {
                let replacement = slot.deletingLastPathComponent().appendingPathComponent(".motionwallpaper-restore-\(UUID().uuidString).mov")
                try? fm.removeItem(at: replacement)
                try fm.copyItem(at: backup, to: replacement)
                _ = try fm.replaceItemAt(slot, withItemAt: replacement)
            }
        }

        try restoreOriginalSystemWallpaperStateIfAvailable()
        try? fm.removeItem(at: stateURL)
        clearWallpaperCaches()
        reloadWallpaperRenderer()
        var settings = WallpaperStore.shared.loadSettings()
        settings.aerialDesktopEnabled = false
        try WallpaperStore.shared.saveSettings(settings)
    }

    /// Alias used by the UI when restoring both the desktop's native background and
    /// the lock screen after stopping the detached desktop video renderer.
    static func restoreAllOriginalWallpapers() throws {
        try restoreOriginalAerial()
    }

    /// The Aerial extension can wedge after a lock/unlock cycle. Restarting only the
    /// renderer after unlock keeps subsequent lock-screen animations alive without
    /// blanking the currently visible lock screen.
    static func resetRendererAfterUnlock() {
        // The macOS 26 workaround interrupts the XPC connection on macOS 27.
        // Temporal HEVC lets the newer renderer finish its own unlock ramp.
        guard isInstalled,
              ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else { return }
        kill("WallpaperAerialsExtension")
    }

    static func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func captureOriginalSystemWallpaperStateIfNeeded() throws {
        try fm.createDirectory(at: originalStateDirectory, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: wallpaperStoreBackupURL.path),
           fm.fileExists(atPath: wallpaperStoreURL.path) {
            try fm.copyItem(at: wallpaperStoreURL, to: wallpaperStoreBackupURL)
        }

        try captureScreenSaverModuleIfNeeded()

        guard let poster = currentLockScreenPosterURL() else { return }
        if fm.fileExists(atPath: lockScreenPosterBackupURL.path) ||
           fm.fileExists(atPath: noLockScreenPosterMarkerURL.path) {
            return
        }

        if fm.fileExists(atPath: poster.path) {
            do {
                try fm.copyItem(at: poster, to: lockScreenPosterBackupURL)
            } catch {
                // The poster cache is best-effort. The wallpaper store backup is the
                // authoritative state and is enough to restore the user's selection.
            }
        } else {
            try? Data().write(to: noLockScreenPosterMarkerURL)
        }
    }

    private static func restoreOriginalSystemWallpaperStateIfAvailable() throws {
        if fm.fileExists(atPath: wallpaperStoreBackupURL.path) {
            let temporary = wallpaperStoreURL.deletingLastPathComponent().appendingPathComponent("Index.motionwallpaper.restore.tmp.plist")
            try? fm.removeItem(at: temporary)
            try fm.copyItem(at: wallpaperStoreBackupURL, to: temporary)
            _ = try fm.replaceItemAt(wallpaperStoreURL, withItemAt: temporary)
        }

        if let poster = currentLockScreenPosterURL() {
            if fm.fileExists(atPath: lockScreenPosterBackupURL.path) {
                let temporary = poster.deletingLastPathComponent().appendingPathComponent(".motionwallpaper-poster-restore-\(UUID().uuidString).png")
                try? fm.removeItem(at: temporary)
                try? fm.copyItem(at: lockScreenPosterBackupURL, to: temporary)
                if fm.fileExists(atPath: temporary.path) {
                    if fm.fileExists(atPath: poster.path) {
                        _ = try? fm.replaceItemAt(poster, withItemAt: temporary)
                    } else {
                        try? fm.moveItem(at: temporary, to: poster)
                    }
                }
            } else if fm.fileExists(atPath: noLockScreenPosterMarkerURL.path) {
                try? fm.removeItem(at: poster)
            }
        }

        try restoreScreenSaverModuleIfAvailable()

        // Remove the snapshot after a successful restore so a future installation
        // captures whatever wallpaper state the user has at that time.
        try? fm.removeItem(at: originalStateDirectory)
    }

    private static func captureScreenSaverModuleIfNeeded() throws {
        if fm.fileExists(atPath: screenSaverModuleBackupURL.path) ||
           fm.fileExists(atPath: noScreenSaverModuleMarkerURL.path) {
            return
        }

        let key = "moduleDict" as CFString
        let appID = "com.apple.screensaver" as CFString
        if let value = CFPreferencesCopyValue(
            key,
            appID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) {
            let data = try PropertyListSerialization.data(
                fromPropertyList: value,
                format: .binary,
                options: 0
            )
            try data.write(to: screenSaverModuleBackupURL, options: [.atomic])
        } else {
            try Data().write(to: noScreenSaverModuleMarkerURL, options: [.atomic])
        }
    }

    private static func restoreScreenSaverModuleIfAvailable() throws {
        let key = "moduleDict" as CFString
        let appID = "com.apple.screensaver" as CFString

        if fm.fileExists(atPath: screenSaverModuleBackupURL.path) {
            let data = try Data(contentsOf: screenSaverModuleBackupURL)
            let value = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            CFPreferencesSetValue(
                key,
                value as CFPropertyList,
                appID,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
            _ = CFPreferencesSynchronize(
                appID,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
        } else if fm.fileExists(atPath: noScreenSaverModuleMarkerURL.path) {
            CFPreferencesSetValue(
                key,
                nil,
                appID,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
            _ = CFPreferencesSynchronize(
                appID,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
        }
    }

    private static func currentLockScreenPosterURL() -> URL? {
        guard let generatedUID = userGeneratedUID() else { return nil }
        return URL(fileURLWithPath: "/Library/Caches/Desktop Pictures/\(generatedUID)/lockscreen.png")
    }

    private static func requireMacOS26() throws {
        guard isSupportedRuntime else { throw InstallError.unsupportedSystem }
    }

    private static func findAerialSlot() throws -> URL {
        if let state = loadState() {
            let remembered = aerialVideosDirectory.appendingPathComponent(state.slotFileName)
            if fm.fileExists(atPath: remembered.path) { return remembered }
        }

        let candidates = (try? fm.contentsOfDirectory(
            at: aerialVideosDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let movies = candidates
            .filter { $0.pathExtension.lowercased() == "mov" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard let slot = movies.first else { throw InstallError.noDownloadedAerial }
        return slot
    }

    private static func backupURL(for slot: URL) -> URL {
        backupDirectory.appendingPathComponent(slot.deletingPathExtension().lastPathComponent + ".original.mov")
    }

    private static func exportAerialMovie(source: URL, preset: String) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let sourceTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = sourceTracks.first else { throw InstallError.noVideoTrack }

        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0.1 else { throw InstallError.videoTooShort }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw InstallError.exportUnavailable
        }

        let targetDuration = CMTime(seconds: targetDurationSeconds, preferredTimescale: 600)
        var cursor = CMTime.zero
        repeat {
            try videoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceVideo,
                at: cursor
            )
            cursor = CMTimeAdd(cursor, duration)
        } while CMTimeCompare(cursor, targetDuration) < 0

        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw InstallError.exportUnavailable
        }
        session.shouldOptimizeForNetworkUse = true

        let output = fm.temporaryDirectory.appendingPathComponent("motionwallpaper-lockscreen-\(UUID().uuidString).mov")
        try? fm.removeItem(at: output)
        do {
            try await session.export(to: output, as: .mov)
            return output
        } catch {
            try? fm.removeItem(at: output)
            throw error
        }
    }

    private static func selectAerialAsset(assetID: String) throws {
        guard fm.fileExists(atPath: wallpaperStoreURL.path),
              let data = try? Data(contentsOf: wallpaperStoreURL),
              var store = try? PropertyListSerialization.propertyList(
                from: data,
                options: [.mutableContainersAndLeaves],
                format: nil
              ) as? [String: Any]
        else {
            throw InstallError.wallpaperStoreMissing
        }

        let configData = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID],
            format: .binary,
            options: 0
        )

        let choice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.aerials",
            "Files": [] as [Any],
            "Configuration": configData
        ]
        let content: [String: Any] = ["Choices": [choice]]
        let linked: [String: Any] = [
            "Content": content,
            "LastSet": Date(),
            "LastUse": Date()
        ]
        let entry: [String: Any] = [
            "Type": "linked",
            "Linked": linked
        ]

        store["SystemDefault"] = entry
        store["AllSpacesAndDisplays"] = entry

        if var displays = store["Displays"] as? [String: Any] {
            for key in displays.keys { displays[key] = entry }
            store["Displays"] = displays
        }

        if var spaces = store["Spaces"] as? [String: Any] {
            for spaceKey in spaces.keys {
                guard var space = spaces[spaceKey] as? [String: Any] else { continue }
                if space["Default"] != nil { space["Default"] = entry }
                if var spaceDisplays = space["Displays"] as? [String: Any] {
                    for displayKey in spaceDisplays.keys { spaceDisplays[displayKey] = entry }
                    space["Displays"] = spaceDisplays
                }
                spaces[spaceKey] = space
            }
            store["Spaces"] = spaces
        }

        let output = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        let temporary = wallpaperStoreURL.deletingLastPathComponent().appendingPathComponent("Index.motionwallpaper.tmp.plist")
        try output.write(to: temporary, options: [.atomic])
        _ = try fm.replaceItemAt(wallpaperStoreURL, withItemAt: temporary)
    }

    private static func configureScreenSaverForAerials() {
        let extensionPath = "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex"
        let result = run("/usr/bin/defaults", [
            "-currentHost", "write", "com.apple.screensaver", "moduleDict",
            "-dict", "moduleName", "WallpaperAerialsExtension",
            "path", extensionPath,
            "type", "0"
        ])
        if result.exitCode != 0 {
            NSLog("MotionWallpaper: could not select WallpaperAerialsExtension as screensaver: %@", result.stderr)
        }
    }

    private static func refreshLockScreenPoster(from videoURL: URL) async {
        guard let generatedUID = userGeneratedUID() else { return }
        let posterDirectory = URL(fileURLWithPath: "/Library/Caches/Desktop Pictures/\(generatedUID)", isDirectory: true)
        guard fm.fileExists(atPath: posterDirectory.path) else { return }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        guard let (frame, _) = try? await generator.image(at: .zero),
              let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])
        else { return }

        let poster = posterDirectory.appendingPathComponent("lockscreen.png")
        let temporary = posterDirectory.appendingPathComponent(".motionwallpaper-lockscreen-\(UUID().uuidString).png")
        do {
            try png.write(to: temporary, options: [.atomic])
            if fm.fileExists(atPath: poster.path) {
                _ = try fm.replaceItemAt(poster, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: poster)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            // Best effort only. The Aerial video itself still works without this poster refresh.
        }
    }

    private static func userGeneratedUID() -> String? {
        let result = run("/usr/bin/dscl", [".", "-read", "/Users/\(NSUserName())", "GeneratedUID"])
        guard result.exitCode == 0 else { return nil }
        return result.stdout
            .split(whereSeparator: { $0.isWhitespace })
            .last
            .map(String.init)
    }

    private static func clearWallpaperCaches() {
        let cacheDirectory = home.appendingPathComponent(
            "Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.aerials",
            isDirectory: true
        )
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "bmp" {
            try? fm.removeItem(at: file)
        }
        let cacheVersion = cacheDirectory.appendingPathComponent("cacheVersion.db")
        try? Data("{\"version\":0}".utf8).write(to: cacheVersion, options: [.atomic])
    }

    private static func reloadWallpaperRenderer() {
        kill("WallpaperAerialsExtension")
        kill("WallpaperAgent")
    }

    private static func kill(_ processName: String) {
        _ = run("/usr/bin/killall", [processName])
    }

    private static func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    private static func saveState(_ state: State) throws {
        try fm.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateURL, options: [.atomic])
    }

    private static func writeReport(source: URL, slot: URL, backup: URL, assetID: String, firstInstall: Bool) throws {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let report: [String: Any] = [
            "installedAt": ISO8601DateFormatter().string(from: Date()),
            "runtimeVersion": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "method": ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
                ? "macos27-temporal-hevc-aerial-slot" : "macos26-aerial-slot",
            "sourceVideo": source.path,
            "aerialAssetID": assetID,
            "slot": slot.path,
            "backup": backup.path,
            "firstInstall": firstInstall,
            "screenSaver": "WallpaperAerialsExtension"
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: reportURL, options: [.atomic])
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, out, err)
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }
}

/// Keeps the Tahoe Aerial renderer healthy across repeated lock/unlock cycles.
final class MacOS26LockScreenRefresher {
    static let shared = MacOS26LockScreenRefresher()

    private var observers: [NSObjectProtocol] = []
    private var isLocked = false

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()

        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isLocked = true
        })

        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isLocked = false
            MacOS26LockScreenInstaller.resetRendererAfterUnlock()
        })
    }
}
