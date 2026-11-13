import AppKit
import ServiceManagement

/// Shared metrics so headers, sliders and percentages line up on the same edges.
private enum MenuLayout {
    /// Space between the menu's edge and its content, the same on both sides.
    static let inset: CGFloat = 14
    static let minimumWidth: CGFloat = 300
    static let percentWidth: CGFloat = 36
    static let percentGap: CGFloat = 8
    /// Text fields pad their text by this much; offsetting by it puts the glyphs on the inset line.
    static let textPadding: CGFloat = 2
}

/// The name of a display above its sliders, aligned with the sliders' left edge.
final class HeaderRow: NSView {
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuLayout.minimumWidth, height: 24))
        autoresizingMask = [.width]
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(
            x: MenuLayout.inset - MenuLayout.textPadding, y: 3,
            width: bounds.width - (MenuLayout.inset - MenuLayout.textPadding) * 2, height: 14)
        label.autoresizingMask = [.width]
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }
}

/// A slider row inside the menu: a Control Center style slider and the level as a percentage.
/// The row stretches to the menu's width; the slider takes all the space the percentage leaves.
final class SliderRow: NSView {
    private let slider: LevelSlider
    private let label = NSTextField(labelWithString: "")

    init(symbol: String, title: String, value: Float?, onChange: @escaping (Float) -> Void) {
        let width = MenuLayout.minimumWidth
        let sliderWidth = width - MenuLayout.inset * 2 - MenuLayout.percentGap - MenuLayout.percentWidth
        slider = LevelSlider(
            frame: NSRect(x: MenuLayout.inset, y: 5, width: sliderWidth, height: 22),
            symbol: symbol, title: title, value: value ?? 0.5)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 32))
        autoresizingMask = [.width]

        slider.autoresizingMask = [.width]
        slider.toolTip = title
        slider.onChange = { [weak self] value in
            self?.show(value)
            onChange(value)
        }
        addSubview(slider)

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        // Centred on the slider's middle line.
        let textHeight = ceil(label.font!.ascender - label.font!.descender)
        label.frame = NSRect(
            x: width - MenuLayout.inset - MenuLayout.percentWidth + MenuLayout.textPadding,
            y: slider.frame.midY - textHeight / 2,
            width: MenuLayout.percentWidth, height: textHeight)
        label.autoresizingMask = [.minXMargin]
        addSubview(label)
        show(value)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func update(_ value: Float?) {
        if let value { slider.value = value }
        show(value)
    }

    private func show(_ value: Float?) {
        label.stringValue = value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
    }
}

final class MenuController: NSObject, NSMenuDelegate {
    private struct RowKey: Hashable {
        let display: CGDirectDisplayID
        let control: Control
    }

    private static let monitorControlBundleID = "me.guillaumeb.MonitorControl"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let manager: DisplayManager
    private let keys: MediaKeyTap
    private var rows: [RowKey: SliderRow] = [:]

    init(manager: DisplayManager, keys: MediaKeyTap) {
        self.manager = manager
        self.keys = keys
        super.init()
        let image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Nits")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Nits – display brightness and volume"
        menu.minimumWidth = MenuLayout.minimumWidth
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Reflects a value change in an open menu.
    func valueChanged(_ display: Display, _ control: Control) {
        rows[RowKey(display: display.id, control: control)]?.update(display.values[control])
    }

    func menuNeedsUpdate(_: NSMenu) {
        keys.syncWithPermission()
        rebuild()
        // Pick up changes made with the monitor's own buttons or the native brightness keys.
        manager.refresh(light: true)
    }

    private func rebuild() {
        menu.removeAllItems()
        rows.removeAll()

        if manager.displays.isEmpty {
            menu.addItem(disabled("No displays found"))
        }
        for display in manager.displays {
            let header = NSMenuItem()
            header.view = HeaderRow(title: display.name)
            menu.addItem(header)
            guard display.isControllable else {
                menu.addItem(disabled("No hardware control (DDC) on this connection"))
                continue
            }
            for control in Control.allCases where isVisible(control, on: display) {
                let row = SliderRow(symbol: control.symbol, title: control.title, value: display.values[control]) {
                    [weak display] value in display?.set(control, to: value)
                }
                let item = NSMenuItem()
                item.view = row
                menu.addItem(item)
                rows[RowKey(display: display.id, control: control)] = row
            }
        }

        menu.addItem(.separator())
        addKeyboardItems()
        menu.addItem(.separator())
        menu.addItem(toggle("Show Volume Sliders", on: Settings.shared.showVolume, #selector(toggleShowVolume)))
        menu.addItem(toggle("Show Contrast Sliders", on: Settings.shared.showContrast, #selector(toggleShowContrast)))
        menu.addItem(toggle("Launch at Login", on: SMAppService.mainApp.status == .enabled, #selector(toggleLoginItem)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Nits", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func isVisible(_ control: Control, on display: Display) -> Bool {
        guard display.supports(control) else { return false }
        switch control {
        case .brightness: return true
        case .contrast: return Settings.shared.showContrast
        case .volume: return Settings.shared.showVolume
        }
    }

    private func addKeyboardItems() {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.monitorControlBundleID).isEmpty {
            menu.addItem(action("MonitorControl Is Also Running – Quit It", #selector(quitMonitorControl)))
        }
        guard MediaKeyTap.isTrusted, keys.isRunning else {
            menu.addItem(action("Enable Brightness & Volume Keys…", #selector(requestKeyAccess)))
            return
        }

        let mode = Settings.shared.brightnessKeyMode
        let brightness = NSMenuItem(title: "Brightness Keys", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, value) in [
            ("Adjust the Display Under the Pointer", BrightnessKeyMode.pointer),
            ("Adjust All Displays", .all),
            ("Leave to macOS", .off),
        ] {
            let item = action(title, #selector(setBrightnessMode(_:)))
            item.representedObject = value.rawValue
            item.state = mode == value ? .on : .off
            submenu.addItem(item)
        }
        brightness.submenu = submenu
        menu.addItem(brightness)
        menu.addItem(toggle("Volume Keys Control Monitor Speakers", on: Settings.shared.volumeKeys, #selector(toggleVolumeKeys)))
    }

    // MARK: Item helpers

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func toggle(_ title: String, on: Bool, _ selector: Selector) -> NSMenuItem {
        let item = action(title, selector)
        item.state = on ? .on : .off
        return item
    }

    // MARK: Actions

    @objc private func requestKeyAccess() {
        MediaKeyTap.requestTrust()
    }

    @objc private func quitMonitorControl() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.monitorControlBundleID).forEach { $0.terminate() }
    }

    @objc private func setBrightnessMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = BrightnessKeyMode(rawValue: raw) else { return }
        Settings.shared.brightnessKeyMode = mode
        keys.settingsChanged()
    }

    @objc private func toggleVolumeKeys() {
        Settings.shared.volumeKeys.toggle()
        keys.settingsChanged()
    }

    @objc private func toggleShowVolume() {
        Settings.shared.showVolume.toggle()
    }

    @objc private func toggleShowContrast() {
        Settings.shared.showContrast.toggle()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
