import AppKit
import CoreGraphics
import Darwin

/// Owns one borderless desktop-level video window for a single display.
final class DesktopVideoController {
    private let screen: NSScreen
    private var window: NSWindow?
    private var videoView: LoopingVideoView?

    init(screen: NSScreen) {
        self.screen = screen
    }

    func show(url: URL, fillScreen: Bool, muted: Bool) {
        close()

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        let view = LoopingVideoView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]

        window.contentView = view
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()

        view.play(url: url, fillScreen: fillScreen, muted: muted)

        self.window = window
        self.videoView = view
    }

    func close() {
        videoView?.stop()
        window?.close()
        videoView = nil
        window = nil
    }
}

/// Starts and controls the detached desktop renderer process. The renderer is a second
/// instance of this executable launched with `--desktop-agent`, so the live desktop
/// wallpaper keeps running after the main UI quits.
final class DesktopWallpaperAgentManager {
    static let shared = DesktopWallpaperAgentManager()

    static let reloadNotification = Notification.Name("com.motionwallpaper.desktop.reload")
    static let stopNotification = Notification.Name("com.motionwallpaper.desktop.stop")

    private let fm = FileManager.default

    private var pidURL: URL {
        WallpaperStore.shared.appSupportDirectory.appendingPathComponent("desktop-agent.pid")
    }

    var isRunning: Bool {
        guard let pid = readPID() else { return false }
        if kill(pid, 0) == 0 { return true }
        try? fm.removeItem(at: pidURL)
        return false
    }

    func startOrReload() throws {
        var settings = WallpaperStore.shared.loadSettings()
        settings.desktopEnabled = true
        settings.aerialDesktopEnabled = false
        try WallpaperStore.shared.saveSettings(settings)

        if isRunning {
            post(Self.reloadNotification)
            return
        }

        guard let executableURL = Bundle.main.executableURL else {
            throw NSError(
                domain: "MotionWallpaper",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Could not locate the Motion Wallpaper executable."]
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--desktop-agent"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? String(process.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
    }

    func stop() throws {
        var settings = WallpaperStore.shared.loadSettings()
        settings.desktopEnabled = false
        settings.aerialDesktopEnabled = false
        try WallpaperStore.shared.saveSettings(settings)
        post(Self.stopNotification)
    }

    func reloadIfRunning() {
        guard isRunning else { return }
        post(Self.reloadNotification)
    }

    private func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func readPID() -> pid_t? {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return pid_t(value)
    }
}

/// Hidden renderer mode used by the detached desktop wallpaper process.
final class DesktopWallpaperAgentDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [DesktopVideoController] = []
    private var observers: [NSObjectProtocol] = []
    private let fm = FileManager.default

    private var pidURL: URL {
        WallpaperStore.shared.appSupportDirectory.appendingPathComponent("desktop-agent.pid")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            try WallpaperStore.shared.ensureDirectories()
            try String(ProcessInfo.processInfo.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("MotionWallpaper: desktop agent could not write its PID: %@", error.localizedDescription)
        }

        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(
            forName: DesktopWallpaperAgentManager.reloadNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadWallpaper()
        })
        observers.append(distributed.addObserver(
            forName: DesktopWallpaperAgentManager.stopNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopAndExit()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadWallpaper()
        })

        reloadWallpaper()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopWallpaper()
        if let text = try? String(contentsOf: pidURL, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines) == String(ProcessInfo.processInfo.processIdentifier) {
            try? fm.removeItem(at: pidURL)
        }
    }

    private func reloadWallpaper() {
        stopWallpaper()

        let settings = WallpaperStore.shared.loadSettings()
        guard settings.desktopEnabled,
              let url = WallpaperStore.shared.selectedURL(for: .desktop)
        else {
            return
        }

        controllers = NSScreen.screens.map { DesktopVideoController(screen: $0) }
        controllers.forEach {
            $0.show(url: url, fillScreen: settings.fillScreen, muted: settings.muted)
        }
    }

    private func stopWallpaper() {
        controllers.forEach { $0.close() }
        controllers.removeAll()
    }

    private func stopAndExit() {
        stopWallpaper()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.terminate(nil)
        }
    }
}
