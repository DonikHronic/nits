import CoreAudio
import Foundation

/// Describes where sound is currently going, so volume keys are only taken over
/// when macOS itself has no way to change the volume.
struct AudioOutput {
    let name: String
    /// True when macOS can adjust this device's volume on its own.
    let hasSystemVolume: Bool
    /// True for audio carried over a display cable (DisplayPort, HDMI, Thunderbolt display).
    let isDisplayAudio: Bool

    static func current() -> AudioOutput? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }

        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)

        var cfName: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &cfName)
        let name = cfName.map { $0.takeRetainedValue() as String } ?? ""

        return AudioOutput(
            name: name,
            hasSystemVolume: hasVolumeControl(device),
            isDisplayAudio: transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI)
    }

    private static func hasVolumeControl(_ device: AudioDeviceID) -> Bool {
        // The virtual main volume is what the system volume slider drives; fall back to per-channel controls.
        let selectors: [(AudioObjectPropertySelector, [UInt32])] = [
            (0x766D_7663 /* 'vmvc', virtual main volume */, [kAudioObjectPropertyElementMain]),
            (kAudioDevicePropertyVolumeScalar, [kAudioObjectPropertyElementMain, 1, 2]),
        ]
        for (selector, elements) in selectors {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                guard AudioObjectHasProperty(device, &address) else { continue }
                var settable: DarwinBoolean = false
                if AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue { return true }
            }
        }
        return false
    }
}
