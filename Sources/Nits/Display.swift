import AppKit
import CoreGraphics

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == id }
    }
}

/// One connected display and the way it can be controlled.
///
/// Values are normalised to 0...1 and owned by the main thread. Hardware access runs on a
/// private serial queue where only the newest requested value is ever written, so dragging
/// a slider or holding a key never builds up a backlog of slow DDC writes.
final class Display {
    enum Backend {
        case ddc(DDCChannel)
        /// Built-in and Apple displays, driven through the same path macOS uses.
        case native
        case none
    }

    let id: CGDirectDisplayID
    let name: String
    let key: String
    let isBuiltin: Bool
    let backend: Backend

    private(set) var values: [Control: Float] = [:]
    /// Controls the display has confirmed by answering a read.
    private(set) var confirmed: Set<Control> = []
    var onChange: ((Display, Control) -> Void)?

    private var lastUserChange: [Control: Date] = [:]
    private var volumeBeforeMute: Float?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [Control: Float] = [:]
    private var draining = false
    // Touched on `queue` only.
    private var maxRaw: [Control: UInt16] = [:]
    private var lastRaw: [Control: UInt16] = [:]

    init(id: CGDirectDisplayID, name: String, backend: Backend) {
        self.id = id
        self.name = name
        self.backend = backend
        isBuiltin = CGDisplayIsBuiltin(id) != 0
        key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
        queue = DispatchQueue(label: "nits.display.\(id)", qos: .userInitiated)
        if case .ddc = backend {
            for control in Control.allCases {
                values[control] = Settings.shared.lastValue(display: key, control: control)
            }
        }
    }

    var isDDC: Bool {
        if case .ddc = backend { return true }
        return false
    }

    var isNative: Bool {
        if case .native = backend { return true }
        return false
    }

    var isControllable: Bool { isDDC || isNative }

    func supports(_ control: Control) -> Bool {
        switch backend {
        case .ddc: return control == .brightness || confirmed.contains(control)
        case .native: return control == .brightness
        case .none: return false
        }
    }

    /// Carries state over from the previous object for the same physical display.
    func adopt(_ old: Display) {
        for (control, value) in old.values where values[control] == nil { values[control] = value }
        confirmed.formUnion(old.confirmed)
        volumeBeforeMute = old.volumeBeforeMute
    }

    // MARK: Setting values (main thread)

    func set(_ control: Control, to value: Float) {
        guard supports(control) else { return }
        let clamped = min(max(value, 0), 1)
        values[control] = clamped
        lastUserChange[control] = Date()
        if isDDC { Settings.shared.setLastValue(clamped, display: key, control: control) }
        onChange?(self, control)

        lock.lock()
        pending[control] = clamped
        let start = !draining
        if start { draining = true }
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// Moves one keyboard step (1/16, or 1/64 when `fine`) and returns the new value.
    @discardableResult
    func step(_ control: Control, up: Bool, fine: Bool) -> Float {
        let steps: Float = fine ? 64 : 16
        let current = values[control] ?? 0.5
        let next = ((current * steps).rounded() + (up ? 1 : -1)) / steps
        if control == .volume { volumeBeforeMute = nil }
        set(control, to: next)
        return values[control] ?? next
    }

    /// Mutes by dropping the volume to zero, which every monitor understands, and restores it on the next toggle.
    @discardableResult
    func toggleMute() -> Float {
        let current = values[.volume] ?? 0
        if current > 0 {
            volumeBeforeMute = current
            set(.volume, to: 0)
        } else {
            set(.volume, to: volumeBeforeMute ?? 0.25)
            volumeBeforeMute = nil
        }
        return values[.volume] ?? 0
    }

    // MARK: Reading values

    /// Re-reads values from the hardware. A `light` refresh only re-reads what is already known to work.
    func refresh(light: Bool = false, retries: Int = 2) {
        switch backend {
        case .none:
            return
        case .native:
            queue.async {
                guard let value = PrivateAPI.nativeBrightness(self.id) else { return }
                DispatchQueue.main.async { self.applyRead(.brightness, value) }
            }
        case let .ddc(channel):
            let controls = light ? Control.allCases.filter { $0 == .brightness || confirmed.contains($0) } : Control.allCases
            queue.async {
                var gotBrightness = false
                for control in controls {
                    if self.hasPending { return }
                    let attempts = control == .brightness ? 4 : 2
                    guard let reply = channel.read(control.vcp, attempts: attempts, shouldAbort: { self.hasPending }) else { continue }
                    self.maxRaw[control] = reply.max
                    self.lastRaw[control] = reply.current
                    if control == .brightness { gotBrightness = true }
                    let value = min(Float(reply.current) / Float(reply.max), 1)
                    DispatchQueue.main.async { self.applyRead(control, value) }
                }
                // Monitors are often deaf for a few seconds after waking or being plugged in.
                if !gotBrightness, retries > 0, !self.hasPending {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh(light: light, retries: retries - 1) }
                }
            }
        }
    }

    private func applyRead(_ control: Control, _ value: Float) {
        let isNew = confirmed.insert(control).inserted
        // A read that was in flight while the user moved the slider is already stale.
        if let touched = lastUserChange[control], Date().timeIntervalSince(touched) < 1.5 {
            if isNew { onChange?(self, control) }
            return
        }
        guard isNew || values[control] != value else { return }
        values[control] = value
        onChange?(self, control)
    }

    // MARK: Hardware queue

    private var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    private func drain() {
        while true {
            lock.lock()
            let batch = pending
            pending.removeAll()
            if batch.isEmpty { draining = false }
            lock.unlock()
            if batch.isEmpty { return }

            for (control, value) in batch {
                switch backend {
                case let .ddc(channel):
                    let raw = UInt16((value * Float(maxRaw[control] ?? 100)).rounded())
                    guard lastRaw[control] != raw else { continue }
                    if channel.write(control.vcp, value: raw) { lastRaw[control] = raw }
                case .native:
                    PrivateAPI.setNativeBrightness(id, value)
                case .none:
                    break
                }
            }
        }
    }
}
