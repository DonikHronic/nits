import AppKit

/// A slider in the style of the ones in Control Center: a capsule track that fills from
/// the left, a round knob at the end of the fill, and the control's icon inside the track.
final class LevelSlider: NSView {
    var value: Float = 0 {
        didSet { needsDisplay = true }
    }

    /// Called continuously while the user drags, clicks or scrolls.
    var onChange: ((Float) -> Void)?

    private let symbol: String
    private let title: String

    init(frame: NSRect, symbol: String, title: String, value: Float) {
        self.symbol = symbol
        self.title = title
        self.value = value
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: Geometry

    private var knobDiameter: CGFloat { bounds.height }

    private var knobRect: NSRect {
        let x = bounds.minX + CGFloat(value) * (bounds.width - knobDiameter)
        return NSRect(x: x, y: bounds.minY, width: knobDiameter, height: knobDiameter)
    }

    /// The value at which the knob would be centred under `point`.
    func value(at point: NSPoint) -> Float {
        let travel = bounds.width - knobDiameter
        guard travel > 0 else { return 0 }
        return Float(min(max((point.x - bounds.minX - knobDiameter / 2) / travel, 0), 1))
    }

    // MARK: Drawing

    override func draw(_: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.12)).setFill()
        track.fill()

        // The fill always reaches the far edge of the knob, so the icon sits on it at every level.
        let knob = knobRect
        let fill = NSRect(x: bounds.minX, y: bounds.minY, width: knob.maxX - bounds.minX, height: bounds.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()

        if !dark {
            // White on a light menu needs an outline to stay visible.
            NSColor.black.withAlphaComponent(0.16).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            outline.lineWidth = 0.5
            outline.stroke()
        }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob.insetBy(dx: 1, dy: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let rim = NSBezierPath(ovalIn: knob.insetBy(dx: 1.25, dy: 1.25))
        rim.lineWidth = 0.5
        rim.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: bounds.height * 0.55, weight: .medium)
            .applying(.init(paletteColors: [NSColor.black.withAlphaComponent(0.55)]))
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = icon.size
            icon.draw(in: NSRect(
                x: bounds.minX + (knobDiameter - size.width) / 2, y: bounds.midY - size.height / 2,
                width: size.width, height: size.height))
        }
    }

    // MARK: Input

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Grabbing the knob drags it from where it was held; clicking the track jumps there.
        let start = convert(event.locationInWindow, from: nil)
        let grabOffset = knobRect.contains(start) ? start.x - knobRect.midX : 0
        update(from: start, offset: grabOffset)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            update(from: convert(next.locationInWindow, from: nil), offset: grabOffset)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        guard delta != 0 else { return }
        commit(value + Float(delta) * (event.hasPreciseScrollingDeltas ? 0.002 : 0.02))
    }

    private func update(from point: NSPoint, offset: CGFloat) {
        commit(value(at: NSPoint(x: point.x - offset, y: point.y)))
    }

    private func commit(_ newValue: Float) {
        let clamped = min(max(newValue, 0), 1)
        guard clamped != value else { return }
        value = clamped
        displayIfNeeded()
        onChange?(clamped)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityValue() -> Any? { NSNumber(value: (value * 100).rounded()) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 100) }

    override func accessibilityPerformIncrement() -> Bool {
        commit(value + 1.0 / 16)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        commit(value - 1.0 / 16)
        return true
    }
}
