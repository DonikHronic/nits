import AppKit

/// The on-screen level indicator shown when a key changes a monitor's brightness or volume.
///
/// macOS draws its current indicator (a small glass pill in the corner of the screen) only for
/// displays it controls itself, and offers other apps nothing but the old square bezel. This is
/// therefore a replica of the current one, built from the same Liquid Glass material.
final class OSD {
    enum Kind {
        case brightness, volume
    }

    static let shared = OSD()
    private var panels: [CGDirectDisplayID: IndicatorPanel] = [:]

    func show(on displayID: CGDirectDisplayID, kind: Kind, value: Float) {
        guard let screen = NSScreen.screen(for: displayID) else { return }
        let value = min(max(value, 0), 1)
        let panel = panels[displayID] ?? {
            let panel = IndicatorPanel()
            panels[displayID] = panel
            return panel
        }()
        panel.present(on: screen, symbol: Self.symbol(for: kind, value: value), value: value)
    }

    /// Drops panels for displays that are gone.
    func prune(keeping ids: Set<CGDirectDisplayID>) {
        for (id, panel) in panels where !ids.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
    }

    private static func symbol(for kind: Kind, value: Float) -> String {
        switch kind {
        case .brightness: return "sun.max.fill"
        case .volume:
            return value <= 0 ? "speaker.slash.fill" : value < 0.34 ? "speaker.wave.1.fill"
                : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }
}

/// The row of 16 segments. Segments fill in quarters, matching the Shift-Option fine steps.
final class SegmentBar: NSView {
    static let segmentCount = 16
    private static let gap: CGFloat = 1.5

    var value: Float = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_: NSRect) {
        let count = CGFloat(Self.segmentCount)
        let width = (bounds.width - Self.gap * (count - 1)) / count
        let lit = CGFloat(value) * count
        for index in 0 ..< Self.segmentCount {
            let rect = NSRect(x: CGFloat(index) * (width + Self.gap), y: 0, width: width, height: bounds.height)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
            NSColor.white.withAlphaComponent(0.28).setFill()
            shape.fill()

            let portion = min(max(lit - CGFloat(index), 0), 1)
            guard portion > 0 else { continue }
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width * portion, height: rect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// The icon and segment bar that sit inside the pill.
final class IndicatorContent: NSView {
    static let size = NSSize(width: 290, height: 60)
    private let icon = NSImageView(frame: NSRect(x: 19, y: 15, width: 30, height: 30))
    private let bar = SegmentBar(frame: NSRect(x: 59, y: 28, width: 203, height: 4))

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white
        addSubview(icon)
        addSubview(bar)
        // A faint shadow keeps the white glyphs readable when the glass is over something bright.
        wantsLayer = true
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 3
            return shadow
        }()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func update(symbol: String, value: Float) {
        let config = NSImage.SymbolConfiguration(pointSize: 21, weight: .medium)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        bar.value = value
    }
}

private final class IndicatorPanel: NSPanel {
    /// Room around the pill so the glass's own shadow is not clipped by the window edge.
    private static let padding: CGFloat = 24
    /// Distance from the top-right corner of the usable screen area.
    private static let margin: CGFloat = 10

    private let content = IndicatorContent()
    private var hideWork: DispatchWorkItem?

    init() {
        let pill = IndicatorContent.size
        let frame = NSRect(x: 0, y: 0, width: pill.width + Self.padding * 2, height: pill.height + Self.padding * 2)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)

        let root = NSView(frame: frame)
        let pillFrame = frame.insetBy(dx: Self.padding, dy: Self.padding)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: pillFrame)
            glass.style = .clear
            glass.cornerRadius = pill.height / 2
            glass.tintColor = NSColor.black.withAlphaComponent(0.16)
            glass.contentView = content
            root.addSubview(glass)
        } else {
            let blur = NSVisualEffectView(frame: pillFrame)
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = pill.height / 2
            blur.layer?.masksToBounds = true
            blur.addSubview(content)
            root.addSubview(blur)
        }
        contentView = root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(on screen: NSScreen, symbol: String, value: Float) {
        content.update(symbol: symbol, value: value)

        // Top-right corner, just under the menu bar, where macOS puts its own indicator.
        let area = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: area.maxX - frame.width + Self.padding - Self.margin,
            y: area.maxY - frame.height + Self.padding - Self.margin))

        hideWork?.cancel()
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
        }
        if alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().alphaValue = 1
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func fadeOut() {
        let work = hideWork
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A newer key press may have revived the panel while it was fading.
            guard let self, self.hideWork === work else { return }
            self.orderOut(nil)
        })
    }
}
