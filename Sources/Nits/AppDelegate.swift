import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = DisplayManager()
    private var keys: MediaKeyTap!
    private var menu: MenuController!

    func applicationDidFinishLaunching(_: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        keys = MediaKeyTap { [weak self] command in self?.perform(command) }
        menu = MenuController(manager: manager, keys: keys)

        manager.onDisplaysChanged = { [weak self] in
            guard let self else { return }
            self.updateRouting()
            OSD.shared.prune(keeping: Set(self.manager.displays.map(\.id)))
        }
        manager.onValueChanged = { [weak self] display, control in
            self?.menu.valueChanged(display, control)
            // Learning that a monitor has speakers changes how volume keys are routed.
            if control == .volume { self?.updateRouting() }
        }
        manager.start()
        keys.syncWithPermission()

        // Fires whenever Accessibility permissions change. Tearing the tap down promptly
        // matters: a tap left active after access is revoked can stall keyboard input.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.keys.syncWithPermission()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.keys.syncWithPermission() }
        }
    }

    private func updateRouting() {
        let ddc = manager.displays.filter(\.isDDC)
        keys.update(routing: KeyRouting(
            ddc: ddc.map { ($0.id, $0.name) },
            volumeCapable: Set(ddc.filter { $0.supports(.volume) }.map(\.id)),
            hasNativeDisplay: manager.displays.contains(where: \.isNative)))
    }

    private func perform(_ command: KeyCommand) {
        switch command {
        case let .brightness(targets, up, fine):
            for id in targets {
                guard let display = manager.display(id) else { continue }
                OSD.shared.show(on: id, kind: .brightness, value: display.step(.brightness, up: up, fine: fine))
            }
        case let .volume(target, up, fine):
            guard let display = manager.display(target) else { return }
            OSD.shared.show(on: target, kind: .volume, value: display.step(.volume, up: up, fine: fine))
        case let .mute(target):
            guard let display = manager.display(target) else { return }
            OSD.shared.show(on: target, kind: .volume, value: display.toggleMute())
        }
    }
}
