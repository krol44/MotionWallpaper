import AppKit
import AVFoundation

final class WallpaperManagerWindowController: NSWindowController,
    NSWindowDelegate,
    NSCollectionViewDataSource,
    NSCollectionViewDelegate,
    NSCollectionViewDelegateFlowLayout,
    NSToolbarDelegate {

    private enum ToolbarID {
        static let addVideo = NSToolbarItem.Identifier("MotionWallpaper.AddVideo")
        static let restoreAll = NSToolbarItem.Identifier("MotionWallpaper.RestoreAll")
        static let wallpaperSettings = NSToolbarItem.Identifier("MotionWallpaper.WallpaperSettings")
    }

    private let collectionView = NSCollectionView()
    private let emptyState = NSStackView()
    private let previewView = LoopingVideoView(frame: .zero)
    private let previewPlaceholder = NSImageView()

    private let selectedTitleLabel = NSTextField(labelWithString: "Select a video")
    private let selectedMetadataLabel = NSTextField(labelWithString: "Choose a video from the library to preview and apply it.")
    private let desktopStatusLabel = NSTextField(labelWithString: "Desktop: Off")
    private let lockStatusLabel = NSTextField(labelWithString: "Lock Screen: Original")
    private let backgroundRendererLabel = NSTextField(labelWithString: "Background renderer: Stopped")

    private let useDesktopButton = NSButton()
    private let useLockScreenButton = NSButton()
    private let useBothButton = NSButton()
    private let stopDesktopButton = NSButton()
    private let restoreLockButton = NSButton()
    private let restoreAllButton = NSButton()
    private let removeButton = NSButton()

    private let startOnLaunchButton = NSButton(checkboxWithTitle: "Start desktop wallpaper when the app launches", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Launch Motion Wallpaper when I log in", target: nil, action: nil)
    private let muteButton = NSButton(checkboxWithTitle: "Mute desktop video", target: nil, action: nil)
    private let fillButton = NSButton(checkboxWithTitle: "Fill screen while preserving aspect ratio", target: nil, action: nil)
    private let loginItemStatusLabel = NSTextField(labelWithString: "")

    private var videos: [VideoItem] = []
    private var selectedVideoID: UUID?
    private var isInstallingLockScreen = false

    var onWindowClosed: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Motion Wallpaper"
        window.subtitle = "macOS 26+"
        window.minSize = NSSize(width: 980, height: 640)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.center()

        self.init(window: window)
        window.delegate = self
        buildToolbar()
        buildUI()
        reload()
    }

    private func buildToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "MotionWallpaper.MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .horizontal
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let library = buildLibraryPane()
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let inspector = buildInspectorPane()
        inspector.translatesAutoresizingMaskIntoConstraints = false
        inspector.widthAnchor.constraint(equalToConstant: 336).isActive = true

        root.addArrangedSubview(library)
        root.addArrangedSubview(separator)
        root.addArrangedSubview(inspector)
    }

    private func buildLibraryPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Video Library")
        title.font = .systemFont(ofSize: 24, weight: .bold)

        let subtitle = NSTextField(labelWithString: "Add videos, preview them, then choose where each one should play.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 238, height: 184)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 8, left: 20, bottom: 20, right: 20)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(VideoCardItem.self, forItemWithIdentifier: VideoCardItem.identifier)
        scrollView.documentView = collectionView
        container.addSubview(scrollView)

        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: "Video library")
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        emptyIcon.contentTintColor = .tertiaryLabelColor

        let emptyTitle = NSTextField(labelWithString: "No videos yet")
        emptyTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        emptyTitle.alignment = .center

        let emptySubtitle = NSTextField(labelWithString: "Add an MP4 or MOV file to build your wallpaper library.")
        emptySubtitle.font = .systemFont(ofSize: 13)
        emptySubtitle.textColor = .secondaryLabelColor
        emptySubtitle.alignment = .center

        let emptyButton = makeButton(
            title: "Add Video…",
            systemImage: "plus",
            action: #selector(addVideo(_:)),
            emphasized: true
        )
        emptyButton.target = self

        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 10
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addArrangedSubview(emptyIcon)
        emptyState.addArrangedSubview(emptyTitle)
        emptyState.addArrangedSubview(emptySubtitle)
        emptyState.addArrangedSubview(emptyButton)
        container.addSubview(emptyState)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyState.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 24),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 380)
        ])

        return container
    }

    private func buildInspectorPane() -> NSView {
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .withinWindow
        material.state = .active

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        material.addSubview(scrollView)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 24, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let previewContainer = NSView()
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.black.cgColor
        previewContainer.layer?.cornerRadius = 12
        previewContainer.layer?.masksToBounds = true
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.heightAnchor.constraint(equalToConstant: 166).isActive = true

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewView)
        previewPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        previewPlaceholder.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "Video preview")
        previewPlaceholder.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        previewPlaceholder.contentTintColor = .tertiaryLabelColor
        previewContainer.addSubview(previewPlaceholder)

        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            previewPlaceholder.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            previewPlaceholder.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor)
        ])

        stack.addArrangedSubview(previewContainer)
        previewContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        selectedTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        selectedTitleLabel.lineBreakMode = .byTruncatingTail
        selectedTitleLabel.maximumNumberOfLines = 1
        stack.addArrangedSubview(selectedTitleLabel)

        selectedMetadataLabel.font = .systemFont(ofSize: 12)
        selectedMetadataLabel.textColor = .secondaryLabelColor
        selectedMetadataLabel.lineBreakMode = .byWordWrapping
        selectedMetadataLabel.maximumNumberOfLines = 3
        stack.addArrangedSubview(selectedMetadataLabel)

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSectionTitle("STATUS"))

        for label in [desktopStatusLabel, lockStatusLabel, backgroundRendererLabel] {
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
        }

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSectionTitle("APPLY"))

        configureActionButton(useDesktopButton, title: "Use on Desktop", image: "display", action: #selector(applyDesktop(_:)), emphasized: true)
        configureActionButton(useLockScreenButton, title: "Use on Lock Screen", image: "lock.rectangle", action: #selector(applyLockScreen(_:)))
        configureActionButton(useBothButton, title: "Use on Desktop & Lock Screen", image: "rectangle.on.rectangle", action: #selector(applyBoth(_:)))

        stack.addArrangedSubview(useDesktopButton)
        stack.addArrangedSubview(useLockScreenButton)
        stack.addArrangedSubview(useBothButton)

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSectionTitle("RESTORE"))

        configureActionButton(stopDesktopButton, title: "Stop Desktop Video", image: "stop.fill", action: #selector(stopDesktop(_:)))
        configureActionButton(restoreLockButton, title: "Restore Original Lock Screen", image: "arrow.uturn.backward", action: #selector(restoreLockScreen(_:)))
        configureActionButton(restoreAllButton, title: "Restore All Original Wallpapers", image: "arrow.counterclockwise", action: #selector(restoreAll(_:)))

        stack.addArrangedSubview(stopDesktopButton)
        stack.addArrangedSubview(restoreLockButton)
        stack.addArrangedSubview(restoreAllButton)

        let restoreHelp = NSTextField(wrappingLabelWithString: "Restore All stops the background renderer and returns the native wallpaper state saved before Motion Wallpaper changed it.")
        restoreHelp.font = .systemFont(ofSize: 11)
        restoreHelp.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(restoreHelp)

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSectionTitle("DESKTOP OPTIONS"))

        startOnLaunchButton.target = self
        startOnLaunchButton.action = #selector(settingsChanged(_:))
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(loginItemChanged(_:))
        muteButton.target = self
        muteButton.action = #selector(settingsChanged(_:))
        fillButton.target = self
        fillButton.action = #selector(settingsChanged(_:))

        for button in [startOnLaunchButton, launchAtLoginButton, muteButton, fillButton] {
            button.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(button)
        }

        let persistenceHelp = NSTextField(wrappingLabelWithString: "Desktop video runs in a lightweight background renderer, so it keeps playing after you quit the main Motion Wallpaper window or UI.")
        persistenceHelp.font = .systemFont(ofSize: 11)
        persistenceHelp.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(persistenceHelp)

        loginItemStatusLabel.font = .systemFont(ofSize: 11)
        loginItemStatusLabel.textColor = .tertiaryLabelColor
        loginItemStatusLabel.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(loginItemStatusLabel)

        stack.addArrangedSubview(makeSeparator())
        configureActionButton(removeButton, title: "Remove from Library", image: "trash", action: #selector(removeVideo(_:)))
        removeButton.contentTintColor = .systemRed
        stack.addArrangedSubview(removeButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: material.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: material.bottomAnchor),

            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        return material
    }

    private func makeSectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func makeButton(title: String, systemImage: String, action: Selector, emphasized: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: emphasized ? .semibold : .regular)
        if let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        if emphasized {
            button.bezelColor = .controlAccentColor
        }
        return button
    }

    private func configureActionButton(_ button: NSButton, title: String, image: String, action: Selector, emphasized: Bool = false) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: emphasized ? .semibold : .regular)
        button.alignment = .center
        if let icon = NSImage(systemSymbolName: image, accessibilityDescription: title) {
            button.image = icon
            button.imagePosition = .imageLeading
        }
        if emphasized {
            button.bezelColor = .controlAccentColor
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.widthAnchor.constraint(equalToConstant: 296).isActive = true
    }

    func reload() {
        let previousSelection = selectedVideoID
        videos = WallpaperStore.shared.loadVideos()

        if let previousSelection, videos.contains(where: { $0.id == previousSelection }) {
            selectedVideoID = previousSelection
        } else {
            let settings = WallpaperStore.shared.loadSettings()
            selectedVideoID = settings.desktopVideoID.flatMap { id in videos.first(where: { $0.id == id })?.id }
                ?? videos.first?.id
        }

        collectionView.reloadData()
        emptyState.isHidden = !videos.isEmpty
        restoreCollectionSelection()
        updateInspector()
    }

    func addVideoFromPicker() {
        addVideo(nil)
    }

    private func restoreCollectionSelection() {
        guard let selectedVideoID,
              let index = videos.firstIndex(where: { $0.id == selectedVideoID })
        else {
            collectionView.selectionIndexPaths = []
            return
        }
        collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
    }

    private var selectedVideo: VideoItem? {
        guard let selectedVideoID else { return nil }
        return videos.first { $0.id == selectedVideoID }
    }

    private func updateInspector() {
        let settings = WallpaperStore.shared.loadSettings()
        let desktopItem = videos.first { $0.id == settings.desktopVideoID }
        let lockItem = videos.first { $0.id == settings.lockScreenVideoID }
        let desktopActive = settings.desktopEnabled && DesktopWallpaperAgentManager.shared.isRunning
        let lockActive = MacOS26LockScreenInstaller.isInstalled
        let hasRestorableWallpaperState = MacOS26LockScreenInstaller.hasRestorableState

        if let item = selectedVideo {
            selectedTitleLabel.stringValue = item.title
            selectedMetadataLabel.stringValue = metadataText(for: item)
            previewPlaceholder.isHidden = true
            previewView.play(url: WallpaperStore.shared.url(for: item), fillScreen: false, muted: true)
        } else {
            selectedTitleLabel.stringValue = "Select a video"
            selectedMetadataLabel.stringValue = "Choose a video from the library to preview and apply it."
            previewView.stop()
            previewPlaceholder.isHidden = false
        }

        desktopStatusLabel.stringValue = desktopActive
            ? "Desktop: Playing \(desktopItem?.title ?? "selected video")"
            : "Desktop: Off"
        lockStatusLabel.stringValue = lockActive
            ? "Lock Screen: \(lockItem?.title ?? "Custom video")"
            : "Lock Screen: Original system wallpaper"
        backgroundRendererLabel.stringValue = DesktopWallpaperAgentManager.shared.isRunning
            ? "Background renderer: Running"
            : "Background renderer: Stopped"

        startOnLaunchButton.state = settings.startDesktopOnLaunch ? .on : .off
        launchAtLoginButton.state = LoginItemManager.isEnabled ? .on : .off
        muteButton.state = settings.muted ? .on : .off
        fillButton.state = settings.fillScreen ? .on : .off
        loginItemStatusLabel.stringValue = "Login item: \(LoginItemManager.statusText)"

        let hasSelection = selectedVideo != nil && !isInstallingLockScreen
        useDesktopButton.isEnabled = hasSelection
        useLockScreenButton.isEnabled = hasSelection
        useBothButton.isEnabled = hasSelection
        removeButton.isEnabled = selectedVideo != nil && !isInstallingLockScreen
        stopDesktopButton.isEnabled = settings.desktopEnabled || DesktopWallpaperAgentManager.shared.isRunning
        restoreLockButton.isEnabled = hasRestorableWallpaperState && !isInstallingLockScreen
        restoreAllButton.isEnabled = (settings.desktopEnabled || hasRestorableWallpaperState || DesktopWallpaperAgentManager.shared.isRunning) && !isInstallingLockScreen
    }

    private func metadataText(for item: VideoItem) -> String {
        let url = WallpaperStore.shared.url(for: item)
        let ext = url.pathExtension.uppercased()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = attributes?[.size] as? Int64 ?? 0
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let date = formatter.string(from: item.dateAdded)
        return [ext.isEmpty ? "VIDEO" : ext, size, "Added \(date)"].joined(separator: "  •  ")
    }

    private func stateText(for item: VideoItem) -> String {
        let settings = WallpaperStore.shared.loadSettings()
        var states: [String] = []
        if settings.desktopVideoID == item.id && settings.desktopEnabled { states.append("Desktop") }
        if settings.lockScreenVideoID == item.id && MacOS26LockScreenInstaller.isInstalled { states.append("Lock Screen") }
        return states.isEmpty ? "Ready" : states.joined(separator: " + ")
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { videos.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: VideoCardItem.identifier, for: indexPath)
        guard let card = item as? VideoCardItem else { return item }
        let video = videos[indexPath.item]
        card.configure(video: video, url: WallpaperStore.shared.url(for: video), status: stateText(for: video))
        return card
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, indexPath.item < videos.count else { return }
        selectedVideoID = videos[indexPath.item].id
        updateInspector()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        if collectionView.selectionIndexPaths.isEmpty {
            selectedVideoID = nil
            updateInspector()
        }
    }

    @objc private func addVideo(_ sender: Any?) {
        guard let url = WallpaperStore.openVideoPicker() else { return }
        do {
            let item = try WallpaperStore.shared.addVideo(from: url)
            selectedVideoID = item.id
            reload()
        } catch {
            showError(error)
        }
    }

    @objc private func applyDesktop(_ sender: Any?) {
        guard let item = selectedVideo else {
            showMessage(title: "Select a Video", text: "Choose a video from the library first.")
            return
        }

        do {
            try WallpaperStore.shared.setSelectedVideo(id: item.id, for: .desktop)
            try DesktopWallpaperAgentManager.shared.startOrReload()
            reload()
        } catch {
            showError(error)
        }
    }

    @objc private func applyLockScreen(_ sender: Any?) {
        guard let item = selectedVideo else {
            showMessage(title: "Select a Video", text: "Choose a video from the library first.")
            return
        }

        do {
            try WallpaperStore.shared.setSelectedVideo(id: item.id, for: .lockScreen)
        } catch {
            showError(error)
            return
        }

        installLockScreen()
    }

    @objc private func applyBoth(_ sender: Any?) {
        guard let item = selectedVideo else {
            showMessage(title: "Select a Video", text: "Choose a video from the library first.")
            return
        }

        do {
            try WallpaperStore.shared.setSelectedVideo(id: item.id, for: .desktop)
            try WallpaperStore.shared.setSelectedVideo(id: item.id, for: .lockScreen)
            try DesktopWallpaperAgentManager.shared.startOrReload()
        } catch {
            showError(error)
            return
        }

        installLockScreen()
    }

    private func installLockScreen() {
        isInstallingLockScreen = true
        lockStatusLabel.stringValue = "Lock Screen: Preparing video…"
        updateInspector()

        Task { @MainActor in
            do {
                _ = try await MacOS26LockScreenInstaller.installSelectedVideo()
                isInstallingLockScreen = false
                reload()
                showMessage(title: "Lock Screen Installed", text: "The selected video is now using the native macOS 26 Aerial lock-screen pipeline.")
            } catch {
                isInstallingLockScreen = false
                reload()
                showError(error)
            }
        }
    }

    @objc private func stopDesktop(_ sender: Any?) {
        do {
            try DesktopWallpaperAgentManager.shared.stop()
            reload()
        } catch {
            showError(error)
        }
    }

    @objc private func restoreLockScreen(_ sender: Any?) {
        do {
            try MacOS26LockScreenInstaller.restoreOriginalAerial()
            reload()
            showMessage(title: "Original Wallpaper Restored", text: "The native wallpaper state saved before Motion Wallpaper changed the lock screen has been restored.")
        } catch {
            showError(error)
        }
    }

    @objc private func restoreAll(_ sender: Any?) {
        do {
            try DesktopWallpaperAgentManager.shared.stop()
            try MacOS26LockScreenInstaller.restoreAllOriginalWallpapers()
            reload()
            showMessage(title: "Motion Wallpaper Disabled", text: "Desktop video playback is stopped and the original native wallpaper state has been restored.")
        } catch {
            showError(error)
        }
    }

    @objc private func removeVideo(_ sender: Any?) {
        guard let item = selectedVideo else { return }

        let alert = NSAlert()
        alert.messageText = "Remove \"\(item.title)\"?"
        alert.informativeText = "The copied video will be removed from the Motion Wallpaper library."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard let window else { return }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try WallpaperStore.shared.removeVideo(id: item.id)
                self?.selectedVideoID = nil

                let settings = WallpaperStore.shared.loadSettings()
                if settings.desktopEnabled, WallpaperStore.shared.selectedURL(for: .desktop) != nil {
                    try DesktopWallpaperAgentManager.shared.startOrReload()
                } else if DesktopWallpaperAgentManager.shared.isRunning {
                    try DesktopWallpaperAgentManager.shared.stop()
                }
                self?.reload()
            } catch {
                self?.showError(error)
            }
        }
    }

    @objc private func settingsChanged(_ sender: Any?) {
        var settings = WallpaperStore.shared.loadSettings()
        settings.startDesktopOnLaunch = startOnLaunchButton.state == .on
        settings.muted = muteButton.state == .on
        settings.fillScreen = fillButton.state == .on

        do {
            try WallpaperStore.shared.saveSettings(settings)
            DesktopWallpaperAgentManager.shared.reloadIfRunning()
            updateInspector()
        } catch {
            showError(error)
        }
    }

    @objc private func loginItemChanged(_ sender: Any?) {
        let shouldEnable = launchAtLoginButton.state == .on
        do {
            try LoginItemManager.setEnabled(shouldEnable)
            var settings = WallpaperStore.shared.loadSettings()
            settings.launchAtLogin = LoginItemManager.isEnabled
            try WallpaperStore.shared.saveSettings(settings)
            updateInspector()
        } catch {
            launchAtLoginButton.state = LoginItemManager.isEnabled ? .on : .off
            updateInspector()
            showError(error)
        }
    }

    @objc private func openWallpaperSettings(_ sender: Any?) {
        MacOS26LockScreenInstaller.openWallpaperSettings()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.addVideo, .flexibleSpace, ToolbarID.restoreAll, ToolbarID.wallpaperSettings]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.addVideo, .flexibleSpace, ToolbarID.restoreAll, ToolbarID.wallpaperSettings]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.addVideo:
            return toolbarButtonItem(
                identifier: itemIdentifier,
                label: "Add Video",
                symbol: "plus",
                action: #selector(addVideo(_:))
            )
        case ToolbarID.restoreAll:
            return toolbarButtonItem(
                identifier: itemIdentifier,
                label: "Restore All",
                symbol: "arrow.counterclockwise",
                action: #selector(restoreAll(_:))
            )
        case ToolbarID.wallpaperSettings:
            return toolbarButtonItem(
                identifier: itemIdentifier,
                label: "Wallpaper Settings",
                symbol: "gearshape",
                action: #selector(openWallpaperSettings(_:))
            )
        default:
            return nil
        }
    }

    private func toolbarButtonItem(identifier: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    func windowWillClose(_ notification: Notification) {
        previewView.stop()
        onWindowClosed?()
    }

    private func showMessage(title: String, text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }
}

private final class VideoCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MotionWallpaper.VideoCard")

    private let cardView = HoverCardView()
    private let thumbnailImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var representedURL: URL?

    override func loadView() {
        view = cardView
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 12
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.backgroundColor = NSColor.black.cgColor
        thumbnailImageView.layer?.cornerRadius = 9
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(thumbnailImageView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(titleLabel)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            thumbnailImageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 8),
            thumbnailImageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -8),
            thumbnailImageView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 8),
            thumbnailImageView.heightAnchor.constraint(equalToConstant: 124),

            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: thumbnailImageView.bottomAnchor, constant: 8),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)
        ])

        cardView.hoverChanged = { [weak self] hovered in
            self?.updateAppearance(hovered: hovered)
        }
    }

    override var isSelected: Bool {
        didSet { updateAppearance(hovered: cardView.isHovered) }
    }

    func configure(video: VideoItem, url: URL, status: String) {
        representedURL = url
        titleLabel.stringValue = video.title
        statusLabel.stringValue = status
        thumbnailImageView.image = NSImage(systemSymbolName: "film", accessibilityDescription: video.title)

        VideoThumbnailProvider.shared.thumbnail(for: url) { [weak self] image in
            guard let self, self.representedURL == url else { return }
            if let image { self.thumbnailImageView.image = image }
        }
    }

    private func updateAppearance(hovered: Bool) {
        if isSelected {
            cardView.layer?.borderColor = NSColor.controlAccentColor.cgColor
            cardView.layer?.borderWidth = 2
            cardView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        } else {
            cardView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            cardView.layer?.borderWidth = 1
            cardView.layer?.backgroundColor = hovered
                ? NSColor.labelColor.withAlphaComponent(0.05).cgColor
                : NSColor.clear.cgColor
        }
    }
}

private final class HoverCardView: NSView {
    var hoverChanged: ((Bool) -> Void)?
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoverChanged?(false)
    }
}

private final class VideoThumbnailProvider {
    static let shared = VideoThumbnailProvider()

    // NSCache is thread-safe and avoids manual locking while thumbnails are generated
    // asynchronously by AVAssetImageGenerator.
    private let cache = NSCache<NSURL, NSImage>()

    func thumbnail(for url: URL, completion: @escaping (NSImage?) -> Void) {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.generateCGImageAsynchronously(for: time) { [weak self] cgImage, _, _ in
            let image = cgImage.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }

            if let image {
                self?.cache.setObject(image, forKey: key)
            }

            DispatchQueue.main.async {
                completion(image)
            }
        }
    }
}
