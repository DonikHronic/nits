import AppKit

// Command-line helpers, handy for scripting and for checking what a monitor supports:
//   Nits --probe                      list displays and the values they report
//   Nits --set brightness 60          set a control (brightness|contrast|volume) to a percentage on all DDC monitors
let arguments = CommandLine.arguments

if arguments.contains("--probe") {
    _ = NSApplication.shared
    for display in DisplayManager.discover() {
        switch display.backend {
        case let .ddc(channel):
            print("\(display.name) [\(display.id)] – DDC")
            for control in Control.allCases {
                if let reply = channel.read(control.vcp, attempts: control == .brightness ? 4 : 2) {
                    print("  \(control.rawValue): \(reply.current) / \(reply.max)")
                } else {
                    print("  \(control.rawValue): no answer")
                }
            }
        case .native:
            let value = PrivateAPI.nativeBrightness(display.id).map { "\(Int(($0 * 100).rounded()))%" } ?? "unreadable"
            print("\(display.name) [\(display.id)] – native brightness \(value)")
        case .none:
            print("\(display.name) [\(display.id)] – not controllable")
        }
    }
    if let output = AudioOutput.current() {
        print("Audio output: \(output.name) – system volume: \(output.hasSystemVolume), display audio: \(output.isDisplayAudio)")
    }
    exit(0)
}

if let index = arguments.firstIndex(of: "--set") {
    guard arguments.count > index + 2, let control = Control(rawValue: arguments[index + 1]),
          let percent = Float(arguments[index + 2]), (0 ... 100).contains(percent)
    else {
        FileHandle.standardError.write(Data("usage: Nits --set brightness|contrast|volume 0-100\n".utf8))
        exit(2)
    }
    _ = NSApplication.shared
    var failed = false
    for display in DisplayManager.discover() {
        guard case let .ddc(channel) = display.backend else { continue }
        let max = channel.read(control.vcp)?.max ?? 100
        let ok = channel.write(control.vcp, value: UInt16((percent / 100 * Float(max)).rounded()))
        print("\(display.name): \(control.rawValue) \(ok ? "set to" : "FAILED to set to") \(Int(percent))%")
        if !ok { failed = true }
    }
    exit(failed ? 1 : 0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
