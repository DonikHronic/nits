import AppKit
import ApplicationServices
import CoreGraphics

enum KeyCommand {
    case brightness(targets: [CGDirectDisplayID], up: Bool, fine: Bool)
    case volume(target: CGDirectDisplayID, up: Bool, fine: Bool)
    case mute(target: CGDirectDisplayID)
}

/// What the key tap needs to know about the current displays. Copied in from the main thread.
struct KeyRouting {
    var ddc: [(id: CGDirectDisplayID, name: String)] = []
    var volumeCapable: Set<CGDirectDisplayID> = []
    /// A display macOS dims itself (built-in or Apple display) is present.
    var hasNativeDisplay = false
}

/// Listens for the brightness and volume keys and takes over only the presses macOS cannot act on.
///
/// Design rules that keep it from getting in the system's way:
/// - A press is swallowed only when it is routed to a DDC monitor; everything else passes through untouched.
/// - The tap is switched off entirely while no DDC monitor is connected.
/// - The tap runs on its own thread and never does slow work, so it cannot delay typing.
/// - If Accessibility access is withdrawn the tap is torn down immediately.
final class MediaKeyTap {
    private enum Key: Hashable { case brightnessUp, brightnessDown, volumeUp, volumeDown, mute }
    private enum Source: Hashable { case system, keyboard }
    private struct Pressed: Hashable {
        let key: Key
        let source: Source
    }

    private let handler: (KeyCommand) -> Void
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?

    private let lock = NSLock()
    private var routing = KeyRouting()

    // Tap-thread state.
    private var swallowed: Set<Pressed> = []
    private var lastDown: (key: Key, source: Source, time: CFAbsoluteTime, swallowed: Bool)?

    init(handler: @escaping (KeyCommand) -> Void) {
        self.handler = handler
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    var isRunning: Bool { port != nil }

    func update(routing new: KeyRouting) {
        lock.lock()
        routing = new
        lock.unlock()
        applyEnabled()
    }

    /// Call after any settings change that affects whether keys are handled at all.
    func settingsChanged() {
        applyEnabled()
    }

    /// Installs or removes the tap to match the current Accessibility permission.
    func syncWithPermission() {
        if Self.isTrusted {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard port == nil else { return }
        let mask: CGEventMask = 1 << 14 /* NX_SYSDEFINED */
            | 1 << CGEventType.keyDown.rawValue
            | 1 << CGEventType.keyUp.rawValue
        guard let newPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        port = newPort

        let thread = Thread { [weak self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newPort, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopRun()
        }
        thread.name = "nits.mediakeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        applyEnabled()
    }

    private func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
        self.port = nil
        runLoop = nil
    }

    private var shouldBeEnabled: Bool {
        lock.lock()
        let hasDDC = !routing.ddc.isEmpty
        lock.unlock()
        return hasDDC && (Settings.shared.brightnessKeyMode != .off || Settings.shared.volumeKeys)
    }

    private func applyEnabled() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: shouldBeEnabled)
    }

    // MARK: Tap thread

    /// Returns true when the event should be swallowed.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port, shouldBeEnabled, Self.isTrusted { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }

        let key: Key
        let source: Source
        let isDown: Bool

        switch type {
        case .keyDown, .keyUp:
            // Recent Apple keyboards deliver the brightness keys as ordinary key codes.
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 144: key = .brightnessUp
            case 145: key = .brightnessDown
            default: return false
            }
            source = .keyboard
            isDown = type == .keyDown
        case _ where type.rawValue == 14:
            guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return false }
            let data = nsEvent.data1
            switch (data & 0xFFFF_0000) >> 16 {
            case 0: key = .volumeUp
            case 1: key = .volumeDown
            case 2: key = .brightnessUp
            case 3: key = .brightnessDown
            case 7: key = .mute
            default: return false
            }
            source = .system
            isDown = (data & 0xFF00) >> 8 == 0xA
        default:
            return false
        }

        let pressed = Pressed(key: key, source: source)
        guard isDown else { return swallowed.remove(pressed) != nil }

        // Some keyboards report one press through both channels; act on it once.
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastDown, last.key == key, last.source != source, now - last.time < 0.05 {
            if last.swallowed { swallowed.insert(pressed) }
            return last.swallowed
        }

        let command = route(key, event: event)
        let swallow = command.map { !passesThrough($0) } ?? false
        lastDown = (key, source, now, swallow)
        guard let command else { return false }
        if swallow { swallowed.insert(pressed) }
        DispatchQueue.main.async { self.handler(command) }
        return swallow
    }

    private func route(_ key: Key, event: CGEvent) -> KeyCommand? {
        let flags = event.flags
        // Leave the system's own shortcuts alone: Control targets Apple displays,
        // Option opens the Displays/Sound settings, Command is never ours.
        if flags.contains(.maskControl) || flags.contains(.maskCommand) { return nil }
        let option = flags.contains(.maskAlternate), shift = flags.contains(.maskShift)
        if option, !shift { return nil }
        let fine = option && shift

        lock.lock()
        let routing = self.routing
        lock.unlock()
        guard !routing.ddc.isEmpty else { return nil }

        switch key {
        case .brightnessUp, .brightnessDown:
            let up = key == .brightnessUp
            switch Settings.shared.brightnessKeyMode {
            case .off:
                return nil
            case .pointer:
                var id: CGDirectDisplayID = 0
                var count: UInt32 = 0
                guard CGGetDisplaysWithPoint(event.location, 1, &id, &count) == .success, count > 0,
                      routing.ddc.contains(where: { $0.id == id })
                else { return nil }
                return .brightness(targets: [id], up: up, fine: fine)
            case .all:
                return .brightness(targets: routing.ddc.map(\.id), up: up, fine: fine)
            }

        case .volumeUp, .volumeDown, .mute:
            guard Settings.shared.volumeKeys,
                  let output = AudioOutput.current(), !output.hasSystemVolume, output.isDisplayAudio
            else { return nil }
            let candidates = routing.ddc.filter { routing.volumeCapable.contains($0.id) }
            let name = output.name.lowercased()
            let match = candidates.first { !name.isEmpty && ($0.name.lowercased().contains(name) || name.contains($0.name.lowercased())) }
            guard let target = match ?? (candidates.count == 1 ? candidates.first : nil) else { return nil }
            if key == .mute { return .mute(target: target.id) }
            return .volume(target: target.id, up: key == .volumeUp, fine: fine)
        }
    }

    /// In "all displays" mode the press must still reach macOS when it has a display of its own to dim.
    fileprivate func passesThrough(_ command: KeyCommand) -> Bool {
        guard case .brightness = command, Settings.shared.brightnessKeyMode == .all else { return false }
        lock.lock()
        defer { lock.unlock() }
        return routing.hasNativeDisplay
    }
}

private func mediaKeyTapCallback(
    proxy _: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
