import AppKit
import AVFoundation

public final class LoopingVideoView: NSView {
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var accessURL: URL?
    private var didStartSecurityScope = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit { stop() }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    public func play(url: URL, fillScreen: Bool = true, muted: Bool = true) {
        stop()
        accessURL = url
        didStartSecurityScope = url.startAccessingSecurityScopedResource()

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVQueuePlayer()
        player.isMuted = muted
        player.actionAtItemEnd = .none

        let looper = AVPlayerLooper(player: player, templateItem: item)
        let avLayer = AVPlayerLayer(player: player)
        avLayer.frame = bounds
        avLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        avLayer.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect

        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer?.addSublayer(avLayer)

        queuePlayer = player
        playerLooper = looper
        playerLayer = avLayer
        player.play()
    }

    public func stop() {
        queuePlayer?.pause()
        queuePlayer = nil
        playerLooper = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        if didStartSecurityScope {
            accessURL?.stopAccessingSecurityScopedResource()
        }
        didStartSecurityScope = false
        accessURL = nil
    }

    public override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }
}
