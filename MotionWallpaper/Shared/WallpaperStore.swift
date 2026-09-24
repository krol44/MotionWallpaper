import AppKit
import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum WallpaperTarget: String, Codable, CaseIterable {
    case desktop
    case lockScreen

    public var title: String {
        switch self {
        case .desktop: return "Desktop"
        case .lockScreen: return "Lock Screen"
        }
    }
}

public struct VideoItem: Codable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var fileName: String
    public var dateAdded: Date
    public var catalogSourceKey: String?
    public var catalogMWID: Int?

    public init(id: UUID = UUID(), title: String, fileName: String, dateAdded: Date = Date(), catalogSourceKey: String? = nil, catalogMWID: Int? = nil) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.dateAdded = dateAdded
        self.catalogSourceKey = catalogSourceKey
        self.catalogMWID = catalogMWID
    }
}

public struct WallpaperSettings: Codable {
    public var desktopVideoID: UUID?
    public var lockScreenVideoID: UUID?
    public var desktopEnabled: Bool
    public var aerialDesktopEnabled: Bool
    public var startDesktopOnLaunch: Bool
    public var launchAtLogin: Bool
    public var muted: Bool
    public var fillScreen: Bool

    public static let defaults = WallpaperSettings(
        desktopVideoID: nil,
        lockScreenVideoID: nil,
        desktopEnabled: true,
        aerialDesktopEnabled: false,
        startDesktopOnLaunch: true,
        launchAtLogin: false,
        muted: true,
        fillScreen: true
    )

    enum CodingKeys: String, CodingKey {
        case desktopVideoID
        case lockScreenVideoID
        case desktopEnabled
        case aerialDesktopEnabled
        case startDesktopOnLaunch
        case launchAtLogin
        case muted
        case fillScreen
    }

    public init(desktopVideoID: UUID?, lockScreenVideoID: UUID?, desktopEnabled: Bool, aerialDesktopEnabled: Bool = false, startDesktopOnLaunch: Bool, launchAtLogin: Bool, muted: Bool, fillScreen: Bool) {
        self.desktopVideoID = desktopVideoID
        self.lockScreenVideoID = lockScreenVideoID
        self.desktopEnabled = desktopEnabled
        self.aerialDesktopEnabled = aerialDesktopEnabled
        self.startDesktopOnLaunch = startDesktopOnLaunch
        self.launchAtLogin = launchAtLogin
        self.muted = muted
        self.fillScreen = fillScreen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        desktopVideoID = try container.decodeIfPresent(UUID.self, forKey: .desktopVideoID)
        lockScreenVideoID = try container.decodeIfPresent(UUID.self, forKey: .lockScreenVideoID)
        desktopEnabled = try container.decodeIfPresent(Bool.self, forKey: .desktopEnabled) ?? true
        aerialDesktopEnabled = try container.decodeIfPresent(Bool.self, forKey: .aerialDesktopEnabled) ?? false
        startDesktopOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .startDesktopOnLaunch) ?? true
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? true
        fillScreen = try container.decodeIfPresent(Bool.self, forKey: .fillScreen) ?? true
    }
}


private final class SynchronousResultBox<Value>: @unchecked Sendable {
    var value: Result<Value, Error>?
}

public final class WallpaperStore {
    public static let shared = WallpaperStore()

    public static let applicationName = "MotionWallpaper"

    public var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(Self.applicationName, isDirectory: true)
    }

    public var videosDirectory: URL {
        appSupportDirectory.appendingPathComponent("Videos", isDirectory: true)
    }

    public var preparedVideosDirectory: URL {
        appSupportDirectory.appendingPathComponent("Prepared/macOS27-v1", isDirectory: true)
    }

    public func preparedURL(for item: VideoItem) -> URL {
        if item.catalogSourceKey != nil, item.catalogMWID != nil { return url(for: item) }
        return preparedVideosDirectory.appendingPathComponent("\(item.id.uuidString).mov")
    }

    public static func catalogSourceKey(for baseURL: URL) -> String {
        SHA256.hash(data: Data(baseURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public func isPreparedForLockScreen(_ item: VideoItem) -> Bool {
        FileManager.default.fileExists(atPath: preparedURL(for: item).path)
    }

    public var picturesDirectory: URL {
        appSupportDirectory.appendingPathComponent("Pictures", isDirectory: true)
    }

    public var libraryFileURL: URL {
        appSupportDirectory.appendingPathComponent("library.json")
    }

    public var settingsFileURL: URL {
        appSupportDirectory.appendingPathComponent("settings.json")
    }

    public var currentDesktopPictureURL: URL {
        picturesDirectory.appendingPathComponent("current-wallpaper.png")
    }

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: picturesDirectory, withIntermediateDirectories: true)
    }

    public func loadVideos() -> [VideoItem] {
        guard let data = try? Data(contentsOf: libraryFileURL),
              let items = try? decoder.decode([VideoItem].self, from: data) else {
            return []
        }
        return items.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    public func saveVideos(_ items: [VideoItem]) throws {
        try ensureDirectories()
        let data = try encoder.encode(items)
        try data.write(to: libraryFileURL, options: [.atomic])
    }

    public func loadSettings() -> WallpaperSettings {
        guard let data = try? Data(contentsOf: settingsFileURL),
              let settings = try? decoder.decode(WallpaperSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    public func saveSettings(_ settings: WallpaperSettings) throws {
        try ensureDirectories()
        let data = try encoder.encode(settings)
        try data.write(to: settingsFileURL, options: [.atomic])
    }

    public func addVideo(from sourceURL: URL) throws -> VideoItem {
        try ensureDirectories()
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension.lowercased()
        let id = UUID()
        let safeTitle = sourceURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationName = "\(id.uuidString).\(ext)"
        let destinationURL = videosDirectory.appendingPathComponent(destinationName)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        var videos = loadVideos()
        let item = VideoItem(id: id, title: safeTitle.isEmpty ? "Video" : safeTitle, fileName: destinationName)
        videos.append(item)
        try saveVideos(videos)

        var settings = loadSettings()
        if settings.desktopVideoID == nil { settings.desktopVideoID = item.id }
        if settings.lockScreenVideoID == nil { settings.lockScreenVideoID = item.id }
        try saveSettings(settings)

        return item
    }

    public func addConvertedCatalogVideo(from convertedURL: URL, title: String, baseURL: URL, mwID: Int) throws -> VideoItem {
        try ensureDirectories()
        let id = UUID()
        let fileName = "\(id.uuidString).mov"
        let destination = videosDirectory.appendingPathComponent(fileName)
        try FileManager.default.moveItem(at: convertedURL, to: destination)
        do {
            let item = VideoItem(id: id, title: title, fileName: fileName,
                                 catalogSourceKey: Self.catalogSourceKey(for: baseURL), catalogMWID: mwID)
            var videos = loadVideos()
            videos.append(item)
            try saveVideos(videos)
            return item
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func removeVideo(id: UUID) throws {
        var videos = loadVideos()
        if let item = videos.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: url(for: item))
            try? FileManager.default.removeItem(at: preparedURL(for: item))
        }
        videos.removeAll { $0.id == id }
        try saveVideos(videos)

        var settings = loadSettings()
        if settings.desktopVideoID == id {
            settings.desktopVideoID = videos.first?.id
            settings.aerialDesktopEnabled = false
        }
        if settings.lockScreenVideoID == id { settings.lockScreenVideoID = videos.first?.id }
        try saveSettings(settings)
    }

    public func item(id: UUID?) -> VideoItem? {
        guard let id else { return nil }
        return loadVideos().first { $0.id == id }
    }

    public func url(for item: VideoItem) -> URL {
        videosDirectory.appendingPathComponent(item.fileName)
    }

    public func selectedURL(for target: WallpaperTarget) -> URL? {
        let settings = loadSettings()
        let selectedID = target == .desktop ? settings.desktopVideoID : settings.lockScreenVideoID
        guard let item = item(id: selectedID) else { return nil }
        return url(for: item)
    }

    public func setSelectedVideo(id: UUID, for target: WallpaperTarget) throws {
        var settings = loadSettings()
        switch target {
        case .desktop:
            settings.desktopVideoID = id
        case .lockScreen:
            settings.lockScreenVideoID = id
        }
        try saveSettings(settings)
    }

    /// Extracts a still frame from the selected desktop video and applies it as the native
    /// macOS wallpaper via NSWorkspace. This is intentionally separate from the live overlay:
    /// the live overlay changes what the user sees on the desktop, while this call changes
    /// Apple's actual Wallpaper setting and System Settings preview.
    @discardableResult
    public func setNativeDesktopPictureFromSelectedVideo() throws -> URL {
        guard let source = selectedURL(for: .desktop) else {
            throw NSError(domain: "MotionWallpaper", code: 404, userInfo: [NSLocalizedDescriptionKey: "No desktop video is selected."])
        }
        let imageURL = try exportStillImage(from: source, to: currentDesktopPictureURL)
        try applyNativeDesktopPicture(imageURL)
        return imageURL
    }

    @discardableResult
    public func setNativeDesktopPictureFromVideo(id: UUID) throws -> URL {
        try setSelectedVideo(id: id, for: .desktop)
        return try setNativeDesktopPictureFromSelectedVideo()
    }

    private func exportStillImage(from videoURL: URL, to outputURL: URL) throws -> URL {
        try ensureDirectories()

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 3840, height: 2160)

        let duration = try loadDurationSynchronously(for: asset)
        let durationSeconds = CMTimeGetSeconds(duration)
        let second = durationSeconds.isFinite && durationSeconds > 2 ? 1.0 : 0.0
        let time = CMTime(seconds: second, preferredTimescale: 600)

        let cgImage = try generateImageSynchronously(using: generator, at: time)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "MotionWallpaper", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not create wallpaper image from the selected video."])
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try data.write(to: outputURL, options: [.atomic])
        return outputURL
    }

    private func loadDurationSynchronously(for asset: AVAsset) throws -> CMTime {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = SynchronousResultBox<CMTime>()

        Task {
            do {
                resultBox.value = .success(try await asset.load(.duration))
            } catch {
                resultBox.value = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        guard let result = resultBox.value else {
            throw NSError(domain: "MotionWallpaper", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not read the selected video's duration."])
        }
        return try result.get()
    }

    private func generateImageSynchronously(using generator: AVAssetImageGenerator, at time: CMTime) throws -> CGImage {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = SynchronousResultBox<CGImage>()

        generator.generateCGImageAsynchronously(for: time) { image, _, error in
            if let error {
                resultBox.value = .failure(error)
            } else if let image {
                resultBox.value = .success(image)
            } else {
                resultBox.value = .failure(NSError(domain: "MotionWallpaper", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not generate an image from the selected video."]))
            }
            semaphore.signal()
        }

        semaphore.wait()
        guard let result = resultBox.value else {
            throw NSError(domain: "MotionWallpaper", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not generate an image from the selected video."])
        }
        return try result.get()
    }

    private func applyNativeDesktopPicture(_ imageURL: URL) throws {
        let workspace = NSWorkspace.shared
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        for screen in screens {
            try workspace.setDesktopImageURL(imageURL, for: screen, options: [:])
        }
    }

    public static func openVideoPicker() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Add Video"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie, .video]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// Compatibility shim for older files or quick experiments.
public enum VideoConfig {
    public static func currentVideoURL() -> URL? { WallpaperStore.shared.selectedURL(for: .desktop) }
    public static func openVideoPicker() -> URL? { WallpaperStore.openVideoPicker() }
    public static func saveVideo(from sourceURL: URL) throws { _ = try WallpaperStore.shared.addVideo(from: sourceURL) }
}
