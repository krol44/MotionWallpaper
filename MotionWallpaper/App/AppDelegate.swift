import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var managerWindowController: WallpaperManagerWindowController?
    private var didFinishLaunchSetup = false
    private var isDockVisible = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didFinishLaunchSetup else { return }
        didFinishLaunchSetup = true
        NSLog("MotionWallpaper: applicationDidFinishLaunching on macOS 26")

        guard MacOS26LockScreenInstaller.isSupportedRuntime else {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let alert = NSAlert()
            alert.messageText = "macOS 26 or Later Required"
            alert.informativeText = "This build requires macOS 26.0 or later. Current system: \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        showDockIcon()

        do {
            try WallpaperStore.shared.ensureDirectories()
        } catch {
            showError(error)
        }

        MacOS26LockScreenRefresher.shared.start()
        setupMainMenu()
        setupStatusMenu()

        let settings = WallpaperStore.shared.loadSettings()
        if settings.startDesktopOnLaunch,
           settings.desktopEnabled,
           WallpaperStore.shared.selectedURL(for: .desktop) != nil {
            do {
                try DesktopWallpaperAgentManager.shared.startOrReload()
            } catch {
                showError(error)
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.showManager(nil)
        }
    }

    /// The detached desktop renderer intentionally survives the main UI process.
    /// Quitting Motion Wallpaper therefore does not stop an active desktop wallpaper.
    func applicationWillTerminate(_ notification: Notification) {}

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showManager(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func setupMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Motion Wallpaper")
        appMenu.addItem(makeMenuItem("About Motion Wallpaper", action: #selector(showAbout(_:))))
        appMenu.addItem(NSMenuItem.separator())

        let hide = makeMenuItem("Hide Motion Wallpaper", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        appMenu.addItem(hide)
        let hideOthers = makeMenuItem("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", target: NSApp)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(makeMenuItem("Show All", action: #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(makeMenuItem("Quit Motion Wallpaper", action: #selector(quit(_:)), key: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(makeMenuItem("Add Video…", action: #selector(addVideo(_:)), key: "o"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(makeMenuItem("Close Window", action: #selector(closeMainWindow(_:)), key: "w"))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(responderMenuItem("Undo", action: Selector(("undo:")), key: "z"))
        let redo = responderMenuItem("Redo", action: Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(responderMenuItem("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(responderMenuItem("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(responderMenuItem("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(responderMenuItem("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(makeMenuItem("Show Motion Wallpaper", action: #selector(showManager(_:)), key: "1"))
        viewMenu.addItem(makeMenuItem("Open Wallpaper Settings…", action: #selector(openWallpaperSettings(_:))))
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let wallpaperItem = NSMenuItem()
        let wallpaperMenu = NSMenu(title: "Wallpaper")
        wallpaperMenu.addItem(makeMenuItem("Start Desktop Wallpaper", action: #selector(startDesktop(_:))))
        wallpaperMenu.addItem(makeMenuItem("Stop Desktop Wallpaper", action: #selector(stopDesktop(_:))))
        wallpaperMenu.addItem(makeMenuItem("Restart Desktop Wallpaper", action: #selector(restartDesktop(_:))))
        wallpaperMenu.addItem(NSMenuItem.separator())
        wallpaperMenu.addItem(makeMenuItem("Install Selected Lock Screen Video", action: #selector(setLockScreenFromMenu(_:))))
        wallpaperMenu.addItem(makeMenuItem("Restore Original Lock Screen", action: #selector(restoreAppleLockScreen(_:))))
        wallpaperMenu.addItem(makeMenuItem("Restore All Original Wallpapers", action: #selector(restoreAllOriginalWallpapers(_:))))
        wallpaperItem.submenu = wallpaperMenu
        mainMenu.addItem(wallpaperItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(makeMenuItem("Minimize", action: #selector(minimizeMainWindow(_:)), key: "m"))
        windowMenu.addItem(makeMenuItem("Zoom", action: #selector(zoomMainWindow(_:))))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(makeMenuItem("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(makeMenuItem("Open Wallpaper Settings", action: #selector(openWallpaperSettings(_:))))
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true

        if let button = item.button {
            if let image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "Motion Wallpaper") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageOnly
                button.title = ""
            } else {
                button.title = "▣"
            }
            button.toolTip = "Motion Wallpaper"
        }

        let menu = NSMenu(title: "Motion Wallpaper")
        menu.autoenablesItems = false
        menu.addItem(makeMenuItem("Open Motion Wallpaper", action: #selector(showManager(_:)), key: "o"))
        menu.addItem(makeMenuItem("Add Video…", action: #selector(addVideo(_:))))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem("Start Desktop Wallpaper", action: #selector(startDesktop(_:))))
        menu.addItem(makeMenuItem("Stop Desktop Wallpaper", action: #selector(stopDesktop(_:))))
        menu.addItem(makeMenuItem("Restart Desktop Wallpaper", action: #selector(restartDesktop(_:))))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem("Install Selected Lock Screen Video", action: #selector(setLockScreenFromMenu(_:))))
        menu.addItem(makeMenuItem("Restore Original Lock Screen", action: #selector(restoreAppleLockScreen(_:))))
        menu.addItem(makeMenuItem("Restore All Original Wallpapers", action: #selector(restoreAllOriginalWallpapers(_:))))
        menu.addItem(makeMenuItem("Open Wallpaper Settings", action: #selector(openWallpaperSettings(_:))))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem("Hide Window & Dock Icon", action: #selector(hideWindowAndDockIcon(_:))))
        menu.addItem(makeMenuItem("Show Dock Icon", action: #selector(showDockIconFromMenu(_:))))
        menu.addItem(makeMenuItem("Quit UI (Wallpaper Keeps Running)", action: #selector(quit(_:)), key: "q"))
        item.menu = menu
        statusItem = item
    }

    private func makeMenuItem(
        _ title: String,
        action: Selector,
        key: String = "",
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        item.isEnabled = true
        return item
    }

    /// Creates a standard responder-chain menu item so AppKit automatically enables
    /// commands such as Undo, Copy, Paste, and Select All only when they apply.
    private func responderMenuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        return item
    }

    @objc private func showManager(_ sender: Any?) {
        if managerWindowController == nil {
            let controller = WallpaperManagerWindowController()
            controller.onWindowClosed = { [weak self] in self?.hideDockIcon() }
            managerWindowController = controller
        }

        managerWindowController?.reload()
        managerWindowController?.showWindow(nil)
        managerWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }


    @objc private func closeMainWindow(_ sender: Any?) {
        managerWindowController?.window?.performClose(sender)
    }

    @objc private func minimizeMainWindow(_ sender: Any?) {
        managerWindowController?.window?.performMiniaturize(sender)
    }

    @objc private func zoomMainWindow(_ sender: Any?) {
        managerWindowController?.window?.performZoom(sender)
    }

    @objc private func hideWindowAndDockIcon(_ sender: Any?) {
        managerWindowController?.window?.orderOut(nil)
        hideDockIcon()
    }

    @objc private func showDockIconFromMenu(_ sender: Any?) {
        showDockIcon()
        showManager(nil)
    }

    private func hideDockIcon() {
        guard isDockVisible else { return }
        isDockVisible = false
        NSApp.setActivationPolicy(.accessory)
    }

    private func showDockIcon() {
        guard !isDockVisible else {
            NSApp.setActivationPolicy(.regular)
            return
        }
        isDockVisible = true
        NSApp.setActivationPolicy(.regular)
    }

    @objc private func addVideo(_ sender: Any?) {
        showManager(nil)
        managerWindowController?.addVideoFromPicker()
    }

    @objc private func startDesktop(_ sender: Any?) {
        do {
            guard WallpaperStore.shared.selectedURL(for: .desktop) != nil else {
                throw NSError(domain: "MotionWallpaper", code: 404, userInfo: [NSLocalizedDescriptionKey: "Choose a desktop video first."])
            }
            try DesktopWallpaperAgentManager.shared.startOrReload()
            managerWindowController?.reload()
        } catch {
            showError(error)
        }
    }

    @objc private func stopDesktop(_ sender: Any?) {
        do {
            try DesktopWallpaperAgentManager.shared.stop()
            managerWindowController?.reload()
        } catch {
            showError(error)
        }
    }

    @objc private func restartDesktop(_ sender: Any?) {
        do {
            try DesktopWallpaperAgentManager.shared.startOrReload()
            managerWindowController?.reload()
        } catch {
            showError(error)
        }
    }

    @objc private func setLockScreenFromMenu(_ sender: Any?) {
        Task { @MainActor in
            do {
                _ = try await MacOS26LockScreenInstaller.installSelectedVideo()
                managerWindowController?.reload()
                showInstalledAlert("The selected video is now installed on the macOS 26 lock screen.")
            } catch {
                showError(error)
            }
        }
    }

    @objc private func restoreAppleLockScreen(_ sender: Any?) {
        do {
            try MacOS26LockScreenInstaller.restoreOriginalAerial()
            managerWindowController?.reload()
            showInstalledAlert("The original system wallpaper state has been restored.")
        } catch {
            showError(error)
        }
    }

    @objc private func restoreAllOriginalWallpapers(_ sender: Any?) {
        do {
            try DesktopWallpaperAgentManager.shared.stop()
            try MacOS26LockScreenInstaller.restoreAllOriginalWallpapers()
            managerWindowController?.reload()
            showInstalledAlert("Motion Wallpaper is disabled and the original system wallpaper state has been restored.")
        } catch {
            showError(error)
        }
    }

    @objc private func openWallpaperSettings(_ sender: Any?) {
        MacOS26LockScreenInstaller.openWallpaperSettings()
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Motion Wallpaper",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0",
            .credits: NSAttributedString(string: "Native video wallpapers for macOS 26 Tahoe.")
        ])
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func showInstalledAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Done"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
