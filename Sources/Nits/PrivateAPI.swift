import CoreGraphics
import Foundation
import IOKit

/// Bindings to the handful of non-public system calls the app needs.
///
/// Everything is resolved at runtime with `dlsym`, so if Apple removes or renames a
/// symbol the corresponding feature quietly turns off instead of the app failing to launch.
enum PrivateAPI {
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let displayServices = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let coreDisplay = dlopen(
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)

    private static func load<T>(_ name: String, from handle: UnsafeMutableRawPointer?, as _: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    // MARK: IOAVService (DDC over DisplayPort/HDMI/Thunderbolt on Apple Silicon)

    private typealias AVCreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias AVCopyEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
    private typealias AVI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let avCreateWithService = load("IOAVServiceCreateWithService", from: rtldDefault, as: AVCreateWithService.self)
    private static let avCopyEDID = load("IOAVServiceCopyEDID", from: rtldDefault, as: AVCopyEDID.self)
    private static let avReadI2C = load("IOAVServiceReadI2C", from: rtldDefault, as: AVI2C.self)
    private static let avWriteI2C = load("IOAVServiceWriteI2C", from: rtldDefault, as: AVI2C.self)

    static var ddcAvailable: Bool { avCreateWithService != nil && avReadI2C != nil && avWriteI2C != nil }

    static func avServiceCreate(_ service: io_service_t) -> CFTypeRef? {
        avCreateWithService?(kCFAllocatorDefault, service)?.takeRetainedValue()
    }

    static func avServiceEDID(_ service: CFTypeRef) -> Data? {
        guard let avCopyEDID else { return nil }
        var edid: Unmanaged<CFData>?
        guard avCopyEDID(service, &edid) == KERN_SUCCESS, let edid else { return nil }
        return edid.takeRetainedValue() as Data
    }

    static func avServiceWrite(_ service: CFTypeRef, chip: UInt32, address: UInt32, bytes: inout [UInt8]) -> Bool {
        guard let avWriteI2C else { return false }
        let count = UInt32(bytes.count)
        return bytes.withUnsafeMutableBytes { avWriteI2C(service, chip, address, $0.baseAddress!, count) } == KERN_SUCCESS
    }

    static func avServiceRead(_ service: CFTypeRef, chip: UInt32, address: UInt32, into bytes: inout [UInt8]) -> Bool {
        guard let avReadI2C else { return false }
        let count = UInt32(bytes.count)
        return bytes.withUnsafeMutableBytes { avReadI2C(service, chip, address, $0.baseAddress!, count) } == KERN_SUCCESS
    }

    // MARK: DisplayServices (brightness of built-in and Apple displays)

    private typealias DSCanChange = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let dsCanChange = load("DisplayServicesCanChangeBrightness", from: displayServices, as: DSCanChange.self)
    private static let dsGet = load("DisplayServicesGetBrightness", from: displayServices, as: DSGet.self)
    private static let dsSet = load("DisplayServicesSetBrightness", from: displayServices, as: DSSet.self)

    static func nativeBrightnessSupported(_ id: CGDirectDisplayID) -> Bool {
        guard let dsCanChange, dsGet != nil, dsSet != nil else { return false }
        return dsCanChange(id)
    }

    static func nativeBrightness(_ id: CGDirectDisplayID) -> Float? {
        guard let dsGet else { return nil }
        var value: Float = 0
        return dsGet(id, &value) == 0 ? value : nil
    }

    @discardableResult
    static func setNativeBrightness(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let dsSet else { return false }
        return dsSet(id, value) == 0
    }

    // MARK: CoreDisplay (where in the IO registry a display is attached)

    private typealias CDInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private static let cdInfo = load("CoreDisplay_DisplayCreateInfoDictionary", from: coreDisplay, as: CDInfo.self)

    static func displayLocation(_ id: CGDirectDisplayID) -> String? {
        guard let info = cdInfo?(id)?.takeRetainedValue() as? [String: Any] else { return nil }
        return info["IODisplayLocation"] as? String
    }
}
