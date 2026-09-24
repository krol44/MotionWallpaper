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
    private let previewPosterView = NSImageView()
    private let previewPlaceholder = NSImageView()

    private let selectedTitleLabel = NSTextField(labelWithString: "Select a video")
    private let selectedMetadataLabel = NSTextField(labelWithString: "Choose a video from the library to preview and apply it.")
    private let desktopStatusLabel = NSTextField(labelWithString: "Desktop: Off")
    private let lockStatusLabel = NSTextField(labelWithString: "Lock Screen: Original")
    private let backgroundRendererLabel = NSTextField(labelWithString: "Background renderer: Stopped")
    private let conversionLabel = NSTextField(labelWithString: "Preparing video…")
    private let conversionProgress = NSProgressIndicator()
    private let cancelConversionButton = NSButton()
    private let conversionStack = NSStackView()

    private let useDesktopButton = NSButton()
    private let useLockScreenButton = NSButton()
    private let useBothButton = NSButton()
    private let prepareButton = NSButton()
    private let downloadButton = NSButton()
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
    private var catalogVideos: [VideoItem] = []
    private var catalogItems: [CatalogVideo] = []
    private var catalogBaseURL: URL?
    private var catalogURLInput = ""
    private var catalogMessage = "Enter a catalog URL and click Update Catalog."
    private var isLoadingCatalog = false
    private weak var catalogHeader: CatalogHeaderView?
    private var selectedVideoID: UUID?
    private var selectedCatalogID: Int?
    private var isInstallingLockScreen = false
    private var installTask: Task<Void, Never>?
    private var catalogDownloadTask: URLSessionDownloadTask?
    private var convertingVideoID: UUID?

    private var needsPreparation: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

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
        restoreSavedCatalog()
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

        let title = NSTextField(labelWithString: "My Videos")
        title.font = .systemFont(ofSize: 24, weight: .bold)

        let subtitle = NSTextField(labelWithString: "Videos added from your Mac.")
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
        collectionView.register(CatalogHeaderView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: CatalogHeaderView.identifier)
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
        previewPosterView.translatesAutoresizingMaskIntoConstraints = false
        previewPosterView.imageScaling = .scaleProportionallyUpOrDown
        previewPosterView.isHidden = true
        previewContainer.addSubview(previewPosterView)
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
            previewPosterView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewPosterView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewPosterView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewPosterView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
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

        conversionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        conversionLabel.textColor = .secondaryLabelColor
        conversionProgress.style = .bar
        conversionProgress.isIndeterminate = false
        conversionProgress.minValue = 0
        conversionProgress.maxValue = 100
        conversionProgress.doubleValue = 0
        conversionProgress.translatesAutoresizingMaskIntoConstraints = false
        conversionProgress.widthAnchor.constraint(equalToConstant: 296).isActive = true
        configureActionButton(cancelConversionButton, title: "Cancel Conversion", image: "xmark.circle", action: #selector(cancelConversion(_:)))
        conversionStack.orientation = .vertical
        conversionStack.alignment = .leading
        conversionStack.spacing = 8
        conversionStack.addArrangedSubview(conversionLabel)
        conversionStack.addArrangedSubview(conversionProgress)
        conversionStack.addArrangedSubview(cancelConversionButton)
        conversionStack.isHidden = true
        stack.addArrangedSubview(conversionStack)

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeSectionTitle("APPLY"))

        configureActionButton(useDesktopButton, title: "Use on Desktop", image: "display", action: #selector(applyDesktop(_:)))
        configureActionButton(useLockScreenButton, title: "Use on Lock Screen", image: "lock.rectangle", action: #selector(applyLockScreen(_:)))
        configureActionButton(useBothButton, title: "Use on Desktop & Lock Screen", image: "rectangle.on.rectangle", action: #selector(applyBoth(_:)))
        configureActionButton(prepareButton, title: "Convert for Lock Screen", image: "arrow.triangle.2.circlepath", action: #selector(convertSelected(_:)))
        configureActionButton(downloadButton, title: "Download & Convert", image: "arrow.down.circle", action: #selector(downloadSelected(_:)), emphasized: true)

        stack.addArrangedSubview(downloadButton)
        stack.addArrangedSubview(prepareButton)
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
        let storedVideos = WallpaperStore.shared.loadVideos()
        videos = storedVideos.filter { $0.catalogSourceKey == nil }
        catalogVideos = storedVideos.filter { $0.catalogSourceKey != nil }

        if selectedCatalogID != nil {
            selectedVideoID = nil
        } else if let previousSelection, videos.contains(where: { $0.id == previousSelection }) {
            selectedVideoID = previousSelection
        } else {
            let settings = WallpaperStore.shared.loadSettings()
            selectedVideoID = settings.desktopVideoID.flatMap { id in videos.first(where: { $0.id == id })?.id }
                ?? videos.first?.id
        }

        collectionView.reloadData()
        emptyState.isHidden = true
        restoreCollectionSelection()
        updateInspector()
    }

    func addVideoFromPicker() {
        addVideo(nil)
    }

    func reinstallConfiguredLockScreenVideo() {
        let settings = WallpaperStore.shared.loadSettings()
        guard let item = WallpaperStore.shared.item(id: settings.lockScreenVideoID) else {
            showMessage(title: "Select a Video", text: "Choose a lock-screen video from the library first.")
            return
        }
        selectedVideoID = item.id
        selectedCatalogID = nil
        reload()
        installLockScreen(item: item, useNativeDesktop: settings.aerialDesktopEnabled)
    }

    private func restoreCollectionSelection() {
        if let selectedCatalogID,
           let index = catalogItems.firstIndex(where: { $0.mwID == selectedCatalogID }) {
            collectionView.selectionIndexPaths = [IndexPath(item: index, section: 1)]
        } else if let selectedVideoID,
                  let index = videos.firstIndex(where: { $0.id == selectedVideoID }) {
            collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        } else {
            collectionView.selectionIndexPaths = []
        }
    }

    private var selectedVideo: VideoItem? {
        if let selectedCatalogID, let catalogBaseURL {
            return catalogVideos.first {
                $0.catalogMWID == selectedCatalogID &&
                    $0.catalogSourceKey == WallpaperStore.catalogSourceKey(for: catalogBaseURL)
            }
        }
        guard let selectedVideoID else { return nil }
        return videos.first { $0.id == selectedVideoID }
    }

    private var selectedCatalogVideo: CatalogVideo? {
        guard let selectedCatalogID else { return nil }
        return catalogItems.first { $0.mwID == selectedCatalogID }
    }

    private func updateInspector() {
        let settings = WallpaperStore.shared.loadSettings()
        let allVideos = videos + catalogVideos
        let desktopItem = allVideos.first { $0.id == settings.desktopVideoID }
        let lockItem = allVideos.first { $0.id == settings.lockScreenVideoID }
        let desktopActive = settings.desktopEnabled && DesktopWallpaperAgentManager.shared.isRunning
        let lockActive = MacOS26LockScreenInstaller.isInstalled
        let hasRestorableWallpaperState = MacOS26LockScreenInstaller.hasRestorableState

        if let item = selectedVideo {
            selectedTitleLabel.stringValue = selectedCatalogVideo?.title ?? item.title
            selectedMetadataLabel.stringValue = selectedCatalogVideo?.metadataText ?? metadataText(for: item)
            previewPosterView.isHidden = true
            previewPosterView.image = nil
            previewView.isHidden = false
            previewPlaceholder.isHidden = true
            previewView.play(url: WallpaperStore.shared.url(for: item), fillScreen: false, muted: true)
        } else if let catalog = selectedCatalogVideo, let catalogBaseURL {
            selectedTitleLabel.stringValue = catalog.title
            selectedMetadataLabel.stringValue = catalog.metadataText
            previewView.stop()
            previewView.isHidden = true
            previewPosterView.image = nil
            previewPosterView.isHidden = false
            previewPlaceholder.isHidden = false
            CatalogPosterProvider.shared.image(for: catalog.posterURL(baseURL: catalogBaseURL)) { [weak self] image in
                guard let self, self.selectedCatalogID == catalog.mwID,
                      self.catalogBaseURL == catalogBaseURL, self.selectedVideo == nil else { return }
                self.previewPosterView.image = image
                self.previewPlaceholder.isHidden = image != nil
            }
        } else {
            selectedTitleLabel.stringValue = "Select a video"
            selectedMetadataLabel.stringValue = "Choose a video from the library to preview and apply it."
            previewView.stop()
            previewView.isHidden = true
            previewPosterView.image = nil
            previewPosterView.isHidden = true
            previewPlaceholder.isHidden = false
        }

        desktopStatusLabel.stringValue = settings.aerialDesktopEnabled && lockActive
            ? "Desktop: Aerial transition (\(desktopItem?.title ?? "selected video"))"
            : desktopActive ? "Desktop: Playing \(desktopItem?.title ?? "selected video")" : "Desktop: Off"
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

        let hasSelection = selectedVideo != nil
        downloadButton.isHidden = selectedCatalogVideo == nil || hasSelection
        downloadButton.isEnabled = selectedCatalogVideo != nil && !isInstallingLockScreen
        let readyForLockScreen = !needsPreparation || selectedVideo.map(WallpaperStore.shared.isPreparedForLockScreen) == true
        prepareButton.isHidden = !needsPreparation || !hasSelection || readyForLockScreen
        prepareButton.isEnabled = hasSelection && !isInstallingLockScreen
        useDesktopButton.isEnabled = hasSelection
        useLockScreenButton.isEnabled = hasSelection && readyForLockScreen && !isInstallingLockScreen
        useBothButton.isEnabled = hasSelection && readyForLockScreen && !isInstallingLockScreen
        removeButton.isHidden = selectedVideo == nil
        removeButton.isEnabled = selectedVideo != nil && !isInstallingLockScreen
        conversionStack.isHidden = !isInstallingLockScreen
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
        if settings.desktopVideoID == item.id && (settings.desktopEnabled || settings.aerialDesktopEnabled) { states.append("Desktop") }
        if settings.lockScreenVideoID == item.id && MacOS26LockScreenInstaller.isInstalled { states.append("Lock Screen") }
        if convertingVideoID == item.id { states.append("Converting…") }
        else if needsPreparation && !WallpaperStore.shared.isPreparedForLockScreen(item) { states.append("Needs conversion") }
        return states.isEmpty ? "Ready" : states.joined(separator: " + ")
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 2 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        section == 0 ? videos.count : catalogItems.count
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> NSSize {
        section == 1 ? NSSize(width: collectionView.bounds.width, height: 140) : .zero
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind,
            withIdentifier: CatalogHeaderView.identifier, for: indexPath)
        guard let header = view as? CatalogHeaderView else { return view }
        catalogHeader = header
        header.configure(url: catalogURLInput, message: catalogMessage, loading: isLoadingCatalog) { [weak self] url in
            self?.loadCatalog(from: url)
        }
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: VideoCardItem.identifier, for: indexPath)
        guard let card = item as? VideoCardItem else { return item }
        if indexPath.section == 0 {
            let video = videos[indexPath.item]
            card.configure(title: video.title, url: WallpaperStore.shared.url(for: video),
                           status: stateText(for: video), downloaded: false)
        } else {
            let catalog = catalogItems[indexPath.item]
            let downloaded = catalogVideos.contains {
                $0.catalogMWID == catalog.mwID &&
                    $0.catalogSourceKey == catalogBaseURL.map(WallpaperStore.catalogSourceKey(for:))
            }
            if let catalogBaseURL {
                card.configure(title: catalog.title, url: catalog.posterURL(baseURL: catalogBaseURL),
                               status: downloaded ? "Downloaded ✓" : catalog.metadataText,
                               downloaded: downloaded, isPoster: true)
            }
        }
        return card
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        if indexPath.section == 0, indexPath.item < videos.count {
            selectedVideoID = videos[indexPath.item].id
            selectedCatalogID = nil
        } else if indexPath.section == 1, indexPath.item < catalogItems.count {
            selectedCatalogID = catalogItems[indexPath.item].mwID
            selectedVideoID = nil
        } else { return }
        updateInspector()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        if collectionView.selectionIndexPaths.isEmpty {
            selectedVideoID = nil
            selectedCatalogID = nil
            updateInspector()
        }
    }

    @objc private func addVideo(_ sender: Any?) {
        guard !isInstallingLockScreen else {
            showMessage(title: "Video Preparation in Progress", text: "Finish or cancel the current operation before adding another video.")
            return
        }
        guard let url = WallpaperStore.openVideoPicker() else { return }
        do {
            let item = try WallpaperStore.shared.addVideo(from: url)
            selectedVideoID = item.id
            selectedCatalogID = nil
            reload()
            if needsPreparation { prepareVideo(item) }
        } catch {
            showError(error)
        }
    }

    private var savedCatalogURL: URL {
        WallpaperStore.shared.appSupportDirectory.appendingPathComponent("catalog.json")
    }

    private func restoreSavedCatalog() {
        guard let data = try? Data(contentsOf: savedCatalogURL),
              let snapshot = try? JSONDecoder().decode(CatalogSnapshot.self, from: data),
              let baseURL = URL(string: snapshot.sourceURL),
              baseURL.scheme?.lowercased() == "https", baseURL.host != nil else { return }
        catalogBaseURL = baseURL
        catalogURLInput = snapshot.sourceURL
        catalogItems = snapshot.entries
        catalogMessage = "\(snapshot.entries.count) saved videos • Update Catalog to refresh"
        catalogHeader?.configure(url: catalogURLInput, message: catalogMessage, loading: false) { [weak self] url in
            self?.loadCatalog(from: url)
        }
    }

    private func saveCatalog(_ entries: [CatalogVideo], from baseURL: URL) throws {
        try WallpaperStore.shared.ensureDirectories()
        let snapshot = CatalogSnapshot(sourceURL: baseURL.absoluteString, entries: entries)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: savedCatalogURL, options: .atomic)
    }

    private func loadCatalog(from input: String) {
        guard !isLoadingCatalog else { return }
        catalogURLInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: catalogURLInput),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            catalogMessage = "Enter a valid HTTPS catalog URL."
            catalogHeader?.setMessage(catalogMessage, loading: false)
            return
        }
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let baseURL = components.url else { return }
        catalogURLInput = baseURL.absoluteString
        isLoadingCatalog = true
        catalogMessage = "Loading catalog…"
        catalogHeader?.setMessage(catalogMessage, loading: true)

        Task { @MainActor in
            defer {
                isLoadingCatalog = false
                catalogHeader?.setMessage(catalogMessage, loading: false)
            }
            do {
                var request = URLRequest(url: baseURL)
                request.timeoutInterval = 30
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw CatalogError.invalidCatalogResponse
                }
                let decoded = try JSONDecoder().decode([CatalogVideo].self, from: data)
                try saveCatalog(decoded, from: baseURL)
                catalogItems = decoded
                catalogBaseURL = baseURL
                selectedCatalogID = nil
                catalogMessage = "\(decoded.count) videos available • Saved locally"
                reload()
            } catch {
                catalogMessage = "Update failed; saved catalog kept: \(error.localizedDescription)"
            }
        }
    }

    @objc private func downloadSelected(_ sender: Any?) {
        guard !isInstallingLockScreen,
              let catalog = selectedCatalogVideo,
              let catalogBaseURL else { return }
        guard catalog.declaredDownloadURL(baseURL: catalogBaseURL) == catalog.fileURL(baseURL: catalogBaseURL) else {
            showMessage(title: "Invalid Catalog Entry", text: "The download path does not match this video's ID.")
            return
        }
        isInstallingLockScreen = true
        conversionLabel.stringValue = "Downloading video… 0%"
        conversionProgress.isIndeterminate = false
        conversionProgress.doubleValue = 0
        cancelConversionButton.title = "Cancel Download"
        cancelConversionButton.isEnabled = true
        updateInspector()

        installTask = Task { @MainActor in
            defer {
                conversionProgress.stopAnimation(nil)
                conversionProgress.isIndeterminate = false
                isInstallingLockScreen = false
                installTask = nil
                reload()
            }
            do {
                let (downloadedURL, response) = try await downloadCatalogFile(from: catalog.fileURL(baseURL: catalogBaseURL))
                defer { try? FileManager.default.removeItem(at: downloadedURL) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw CatalogError.invalidVideoResponse
                }
                conversionProgress.stopAnimation(nil)
                conversionProgress.isIndeterminate = false
                conversionProgress.doubleValue = 0
                conversionLabel.stringValue = "Converting video…"
                cancelConversionButton.title = "Cancel Conversion"
                let encoded = try await AerialTemporalEncoder.encode(source: downloadedURL) { value in
                    DispatchQueue.main.async { self.updateConversionProgress(value) }
                }
                defer { try? FileManager.default.removeItem(at: encoded) }
                try Task.checkCancellation()
                _ = try WallpaperStore.shared.addConvertedCatalogVideo(
                    from: encoded, title: catalog.title, baseURL: catalogBaseURL, mwID: catalog.mwID)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    conversionLabel.stringValue = "Download cancelled"
                } else {
                    showError(error)
                }
            }
        }
    }

    private func downloadCatalogFile(from url: URL) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        var progressTimer: Timer?
        defer {
            progressTimer?.invalidate()
            catalogDownloadTask = nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location, let response else {
                    continuation.resume(throwing: CatalogError.invalidVideoResponse)
                    return
                }
                // URLSession deletes its temporary file after this callback returns.
                let ownedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("motionwallpaper-download-\(UUID().uuidString).mp4")
                do {
                    try FileManager.default.moveItem(at: location, to: ownedURL)
                    continuation.resume(returning: (ownedURL, response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            catalogDownloadTask = task
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak task] _ in
                guard let task else { return }
                let expected = task.countOfBytesExpectedToReceive > 0
                    ? task.countOfBytesExpectedToReceive : task.response?.expectedContentLength ?? -1
                self?.updateDownloadProgress(received: task.countOfBytesReceived,
                                             expected: expected)
            }
            task.resume()
        }
    }

    private func updateDownloadProgress(received: Int64, expected: Int64) {
        guard isInstallingLockScreen, catalogDownloadTask != nil,
              installTask?.isCancelled != true else { return }
        guard expected > 0 else {
            let size = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            conversionLabel.stringValue = "Downloading video… \(size)"
            return
        }
        let percent = min(99, max(0, Int(Double(received) / Double(expected) * 100)))
        conversionProgress.doubleValue = Double(percent)
        conversionLabel.stringValue = "Downloading video… \(percent)%"
    }

    @objc private func convertSelected(_ sender: Any?) {
        guard let item = selectedVideo else { return }
        prepareVideo(item)
    }

    private func prepareVideo(_ item: VideoItem) {
        guard !isInstallingLockScreen else { return }
        isInstallingLockScreen = true
        convertingVideoID = item.id
        conversionProgress.doubleValue = 0
        conversionLabel.stringValue = "Preparing video…"
        cancelConversionButton.title = "Cancel Conversion"
        cancelConversionButton.isEnabled = true
        updateInspector()
        collectionView.reloadData()

        installTask = Task { @MainActor in
            defer {
                convertingVideoID = nil
                isInstallingLockScreen = false
                installTask = nil
                reload()
            }
            do {
                try await MacOS26LockScreenInstaller.prepare(item: item) { value in
                    DispatchQueue.main.async { self.updateConversionProgress(value) }
                }
            } catch is CancellationError {
                conversionLabel.stringValue = "Conversion cancelled"
            } catch {
                showError(error)
            }
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

        installLockScreen(item: item, useNativeDesktop: false)
    }

    @objc private func applyBoth(_ sender: Any?) {
        guard let item = selectedVideo else {
            showMessage(title: "Select a Video", text: "Choose a video from the library first.")
            return
        }

        installLockScreen(item: item, useNativeDesktop: true)
    }

    private func installLockScreen(item: VideoItem, useNativeDesktop: Bool) {
        guard !isInstallingLockScreen else { return }
        guard !needsPreparation || WallpaperStore.shared.isPreparedForLockScreen(item) else {
            showMessage(title: "Conversion Required", text: "Convert this video for the macOS 27 lock screen first.")
            return
        }
        isInstallingLockScreen = true
        conversionProgress.doubleValue = 0
        conversionLabel.stringValue = "Preparing video…"
        cancelConversionButton.title = "Cancel Conversion"
        cancelConversionButton.isEnabled = true
        updateInspector()

        let store = WallpaperStore.shared
        let videoURL = store.url(for: item)
        installTask = Task { @MainActor in
            defer {
                isInstallingLockScreen = false
                installTask = nil
                reload()
            }
            do {
                _ = try await MacOS26LockScreenInstaller.install(
                    videoURL: videoURL,
                    preparedURL: needsPreparation ? store.preparedURL(for: item) : nil
                ) { value in
                    DispatchQueue.main.async {
                        self.updateConversionProgress(value)
                    }
                }
                try store.setSelectedVideo(id: item.id, for: .lockScreen)
                if useNativeDesktop {
                    try DesktopWallpaperAgentManager.shared.stop()
                    var settings = store.loadSettings()
                    settings.desktopVideoID = item.id
                    settings.aerialDesktopEnabled = true
                    try store.saveSettings(settings)
                } else {
                    var settings = store.loadSettings()
                    settings.aerialDesktopEnabled = false
                    try store.saveSettings(settings)
                }
                showMessage(title: "Wallpaper Installed", text: useNativeDesktop
                    ? "The video now plays on the lock screen and slows to a stop on the desktop."
                    : "The selected video is now installed on the lock screen.")
            } catch is CancellationError {
                conversionLabel.stringValue = "Conversion cancelled"
            } catch {
                showError(error)
            }
        }
    }

    private func updateConversionProgress(_ value: Double) {
        guard isInstallingLockScreen, installTask?.isCancelled != true else { return }
        conversionProgress.doubleValue = value * 100
        if value >= 1 {
            conversionLabel.stringValue = convertingVideoID != nil || selectedCatalogID != nil
                ? "Finishing conversion…" : "Applying to Lock Screen…"
            cancelConversionButton.isEnabled = false
        } else {
            conversionLabel.stringValue = "Encoding video… \(Int(value * 100))%"
        }
    }

    @objc private func cancelConversion(_ sender: Any?) {
        guard isInstallingLockScreen else { return }
        conversionLabel.stringValue = catalogDownloadTask == nil
            ? "Cancelling conversion…" : "Cancelling download…"
        cancelConversionButton.isEnabled = false
        installTask?.cancel()
        catalogDownloadTask?.cancel()
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

private struct CatalogSnapshot: Codable {
    let sourceURL: String
    let entries: [CatalogVideo]
}

private struct CatalogVideo: Codable {
    let title: String
    let mwID: Int
    let downloadURL: String
    let durationSeconds: Double
    let fileSize: Int64

    enum CodingKeys: String, CodingKey {
        case title, mwID
        case downloadURL = "download_url"
        case durationSeconds = "duration_seconds"
        case fileSize = "file_size"
    }

    var metadataText: String {
        let duration = "\(Int(durationSeconds))s"
        let size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        return "\(duration)  •  \(size)"
    }

    func fileURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("file").appendingPathComponent("\(mwID).mp4")
    }

    func posterURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("file").appendingPathComponent("\(mwID).jpeg")
    }

    func declaredDownloadURL(baseURL: URL) -> URL? {
        URL(string: downloadURL, relativeTo: baseURL)?.absoluteURL
    }
}

private enum CatalogError: LocalizedError {
    case invalidCatalogResponse
    case invalidVideoResponse

    var errorDescription: String? {
        switch self {
        case .invalidCatalogResponse: return "The catalog server did not return a catalog successfully."
        case .invalidVideoResponse: return "The catalog server did not return the video successfully."
        }
    }
}

private final class CatalogHeaderView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("MotionWallpaper.CatalogHeader")

    private let titleLabel = NSTextField(labelWithString: "Online Catalog")
    private let subtitleLabel = NSTextField(labelWithString: "Paste a catalog URL to load or refresh the saved catalog.")
    private let urlField = NSTextField()
    private let loadButton = NSButton(title: "Update Catalog", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private var onLoad: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        urlField.placeholderString = "https://your-catalog.example/videos/"
        urlField.font = .systemFont(ofSize: 12)
        loadButton.bezelStyle = .rounded
        loadButton.target = self
        loadButton.action = #selector(load(_:))
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor

        for subview in [titleLabel, subtitleLabel, urlField, loadButton, messageLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            urlField.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            urlField.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            urlField.heightAnchor.constraint(equalToConstant: 30),
            loadButton.leadingAnchor.constraint(equalTo: urlField.trailingAnchor, constant: 8),
            loadButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            loadButton.centerYAnchor.constraint(equalTo: urlField.centerYAnchor),
            loadButton.widthAnchor.constraint(equalToConstant: 120),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            messageLabel.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 7)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(url: String, message: String, loading: Bool, onLoad: @escaping (String) -> Void) {
        urlField.stringValue = url
        self.onLoad = onLoad
        setMessage(message, loading: loading)
    }

    func setMessage(_ message: String, loading: Bool) {
        messageLabel.stringValue = message
        loadButton.isEnabled = !loading
        loadButton.title = loading ? "Loading…" : "Update Catalog"
    }

    @objc private func load(_ sender: Any?) { onLoad?(urlField.stringValue) }
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

    func configure(title: String, url: URL, status: String, downloaded: Bool, isPoster: Bool = false) {
        representedURL = url
        titleLabel.stringValue = title
        statusLabel.stringValue = status
        statusLabel.textColor = downloaded ? .systemGreen : .secondaryLabelColor
        thumbnailImageView.image = NSImage(systemSymbolName: "film", accessibilityDescription: title)

        let receiveImage: (NSImage?) -> Void = { [weak self] image in
            guard let self, self.representedURL == url else { return }
            if let image { self.thumbnailImageView.image = image }
        }
        if isPoster {
            CatalogPosterProvider.shared.image(for: url, completion: receiveImage)
        } else {
            VideoThumbnailProvider.shared.thumbnail(for: url, completion: receiveImage)
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

private final class CatalogPosterProvider {
    static let shared = CatalogPosterProvider()

    private let cache = NSCache<NSURL, NSImage>()
    private var pending: [URL: [(NSImage?) -> Void]] = [:]

    func image(for url: URL, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache.object(forKey: url as NSURL) {
            completion(cached)
            return
        }
        if pending[url] != nil {
            pending[url]?.append(completion)
            return
        }
        pending[url] = [completion]

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let validResponse = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                let image = validResponse ? data.flatMap(NSImage.init(data:)) : nil
                if let image { self.cache.setObject(image, forKey: url as NSURL) }
                let callbacks = self.pending.removeValue(forKey: url) ?? []
                callbacks.forEach { $0(image) }
            }
        }.resume()
    }
}
