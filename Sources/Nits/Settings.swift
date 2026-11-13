import Foundation

enum Control: String, CaseIterable {
    case brightness, contrast, volume

    var vcp: UInt8 {
        switch self {
        case .brightness: return 0x10
        case .contrast: return 0x12
        case .volume: return 0x62
        }
    }

    var symbol: String {
        switch self {
        case .brightness: return "sun.max.fill"
        case .contrast: return "circle.lefthalf.filled"
        case .volume: return "speaker.wave.2.fill"
        }
    }

    var title: String { rawValue.capitalized }
}

enum BrightnessKeyMode: String {
    /// Keys adjust the display the pointer is on. On the built-in display macOS handles them itself.
    case pointer
    /// Keys adjust every display at once.
    case all
    /// Keys are left entirely to macOS.
    case off
}

/// User preferences. `UserDefaults` is thread-safe, so this is read from the key-tap thread too.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "brightnessKeyMode": BrightnessKeyMode.pointer.rawValue,
            "volumeKeys": true,
            "showContrast": false,
            "showVolume": true,
        ])
    }

    var brightnessKeyMode: BrightnessKeyMode {
        get { BrightnessKeyMode(rawValue: defaults.string(forKey: "brightnessKeyMode") ?? "") ?? .pointer }
        set { defaults.set(newValue.rawValue, forKey: "brightnessKeyMode") }
    }

    var volumeKeys: Bool {
        get { defaults.bool(forKey: "volumeKeys") }
        set { defaults.set(newValue, forKey: "volumeKeys") }
    }

    var showContrast: Bool {
        get { defaults.bool(forKey: "showContrast") }
        set { defaults.set(newValue, forKey: "showContrast") }
    }

    var showVolume: Bool {
        get { defaults.bool(forKey: "showVolume") }
        set { defaults.set(newValue, forKey: "showVolume") }
    }

    /// Last value the user set, used to seed the slider when a monitor does not answer reads.
    func lastValue(display key: String, control: Control) -> Float? {
        defaults.object(forKey: "value.\(key).\(control.rawValue)") as? Float
    }

    func setLastValue(_ value: Float, display key: String, control: Control) {
        defaults.set(value, forKey: "value.\(key).\(control.rawValue)")
    }
}
