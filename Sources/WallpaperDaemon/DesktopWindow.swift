import AVFoundation
import Cocoa

/// A borderless, click-through window pinned between desktop wallpaper and desktop icons.
/// Pattern derived from LiveDesk and Aereo open-source projects.
final class DesktopWindow: NSWindow {
    private var playerLayer: AVPlayerLayer?

    convenience init(screen: NSScreen) {
        self.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )

        // Position: above system wallpaper, below desktop icons
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

        // Behavior: visible on all Spaces, doesn't animate on Space switch, excluded from Cmd+`
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true // Click-through to desktop
        isReleasedWhenClosed = false
        // Must stay capturable: .none makes screenshots show a gray desktop (macOS 27).
        // Screen Time invisibility comes from the bare Mach-O, not window sharing.
        sharingType = .readOnly
        animationBehavior = .none // No animation on show/hide

        // Set up content view with layer backing
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        contentView = view
    }

    /// Never steal focus from other apps
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    // MARK: - Video Layer

    func attachPlayer(_ player: AVPlayer, gravity: AVLayerVideoGravity = .resizeAspectFill) {
        // Remove existing layer
        playerLayer?.removeFromSuperlayer()

        guard let contentView else { return }

        let layer = AVPlayerLayer(player: player)
        layer.frame = contentView.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = gravity
        contentView.layer?.addSublayer(layer)

        playerLayer = layer
    }

    func detachPlayer() {
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    /// Update frame to match current screen geometry (e.g., after resolution change)
    func updateFrame(for screen: NSScreen) {
        setFrame(screen.frame, display: false)
        if let contentView {
            playerLayer?.frame = contentView.bounds
        }
    }

    /// Show the window behind everything else (use orderBack, not orderFront)
    func showOnDesktop() {
        orderBack(nil)
    }
}
