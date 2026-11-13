import AppKit
import CoreGraphics

/// Keeps the list of connected displays current across plug/unplug, sleep and wake.
final class DisplayManager {
    private(set) var displays: [Display] = []
    var onDisplaysChanged: (() -> Void)?
    var onValueChanged: ((Display, Control) -> Void)?

    private var pendingRebuild: DispatchWorkItem?

    func display(_ id: CGDirectDisplayID) -> Display? {
        displays.first { $0.id == id }
    }

    func start() {
        rebuild()
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard let context, !flags.contains(.beginConfigurationFlag) else { return }
            let manager = Unmanaged<DisplayManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { manager.scheduleRebuild(after: 1.5) }
        }, context)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRebuild(after: 3)
            }
        }
    }

    /// Display changes arrive in bursts, so wait for things to settle before touching the hardware.
    func scheduleRebuild(after delay: TimeInterval) {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func rebuild() {
        let previous = displays
        displays = Self.discover()
        for display in displays {
            if let old = previous.first(where: { $0.id == display.id && $0.key == display.key }) {
                display.adopt(old)
            }
            display.onChange = { [weak self] display, control in self?.onValueChanged?(display, control) }
            display.refresh()
        }
        onDisplaysChanged?()
    }

    func refresh(light: Bool) {
        displays.forEach { $0.refresh(light: light) }
    }

    static func discover() -> [Display] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        ids = Array(ids.prefix(Int(count)))

        let external = ids.filter { CGDisplayIsBuiltin($0) == 0 && !PrivateAPI.nativeBrightnessSupported($0) }
        let services = AVServiceLocator.match(displays: external)

        let found = ids.map { id -> Display in
            let name = NSScreen.screen(for: id)?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display")
            let backend: Display.Backend
            if let service = services[id] {
                backend = .ddc(DDCChannel(service: service))
            } else if PrivateAPI.nativeBrightnessSupported(id) {
                backend = .native
            } else {
                backend = .none
            }
            return Display(id: id, name: name, backend: backend)
        }
        // External monitors first: they are what the app is for.
        return found.filter { !$0.isBuiltin } + found.filter { $0.isBuiltin }
    }
}
