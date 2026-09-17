import AppKit

@main
struct MotionWallpaperMain {
    static func main() {
        let app = NSApplication.shared

        if CommandLine.arguments.contains("--desktop-agent") {
            let delegate = DesktopWallpaperAgentDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) {
                app.run()
            }
            return
        }

        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
