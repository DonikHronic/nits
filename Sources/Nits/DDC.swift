import CoreGraphics
import Foundation
import IOKit

/// A DDC/CI connection to one external display. Calls block for tens of milliseconds,
/// so they must only be made from a background queue.
final class DDCChannel {
    private let service: CFTypeRef
    private static let chip: UInt32 = 0x37
    private static let address: UInt32 = 0x51
    /// Request checksum seed this monitor has answered to.
    private var readSeed: UInt8?

    init(service: CFTypeRef) {
        self.service = service
    }

    /// Reads a VCP feature. `shouldAbort` lets a pending write cut a slow read short.
    func read(_ vcp: UInt8, attempts: Int = 4, shouldAbort: () -> Bool = { false }) -> (current: UInt16, max: UInt16)? {
        var packet: [UInt8] = [0x82, 0x01, vcp, 0]
        for attempt in 0 ..< attempts {
            if shouldAbort() { return nil }
            // The DDC/CI spec checksums the request over both bus addresses (0x6E ^ 0x51). Strict
            // monitors reject anything else with a null reply, while some only answer the
            // shorter 0x6E form many Mac tools send. Alternate until one works, then stick to it.
            let seed = readSeed ?? (attempt % 2 == 0 ? 0x6E ^ 0x51 : 0x6E)
            packet[3] = seed ^ packet[0] ^ packet[1] ^ packet[2]
            for _ in 0 ..< 2 {
                usleep(10000)
                _ = PrivateAPI.avServiceWrite(service, chip: Self.chip, address: Self.address, bytes: &packet)
            }
            usleep(50000)
            var reply = [UInt8](repeating: 0, count: 11)
            if PrivateAPI.avServiceRead(service, chip: Self.chip, address: Self.address, into: &reply),
               let result = Self.parse(reply, vcp: vcp) {
                readSeed = seed
                return result
            }
            usleep(20000)
        }
        return nil
    }

    @discardableResult
    func write(_ vcp: UInt8, value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = packet[0 ..< 5].reduce(0x6E ^ 0x51, ^)
        var ok = false
        for _ in 0 ..< 2 {
            usleep(10000)
            if PrivateAPI.avServiceWrite(service, chip: Self.chip, address: Self.address, bytes: &packet) { ok = true }
        }
        return ok
    }

    private static func parse(_ reply: [UInt8], vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard reply.count == 11,
              reply[0 ..< 10].reduce(0x50, ^) == reply[10],
              reply[2] == 0x02, // "get VCP feature" reply
              reply[3] == 0x00, // no error
              reply[4] == vcp
        else { return nil }
        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard max > 0 else { return nil }
        return (current, max)
    }
}

/// Finds the DDC service that belongs to each external display.
enum AVServiceLocator {
    struct Candidate {
        let service: CFTypeRef
        /// Registry node of the display pipe this service hangs off, e.g. `dispext0@C0000000`.
        let node: String?
        let vendor: UInt32?
        let product: UInt32?
        let serial: UInt32?
    }

    static func externalServices() -> [Candidate] {
        guard PrivateAPI.ddcAvailable else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [Candidate] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let service = PrivateAPI.avServiceCreate(entry) else { continue }

            var vendor: UInt32?, product: UInt32?, serial: UInt32?
            if let edid = PrivateAPI.avServiceEDID(service), edid.count >= 16 {
                let b = [UInt8](edid.prefix(16))
                vendor = UInt32(b[8]) << 8 | UInt32(b[9])
                product = UInt32(b[10]) | UInt32(b[11]) << 8
                serial = UInt32(b[12]) | UInt32(b[13]) << 8 | UInt32(b[14]) << 16 | UInt32(b[15]) << 24
            }
            result.append(Candidate(service: service, node: pipeNode(above: entry), vendor: vendor, product: product, serial: serial))
        }
        return result
    }

    /// Pairs each external display with its service: first by where it is plugged in,
    /// then by EDID identity, and finally by elimination.
    static func match(displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: CFTypeRef] {
        var free = externalServices()
        var remaining = displays
        var result: [CGDirectDisplayID: CFTypeRef] = [:]
        guard !free.isEmpty, !remaining.isEmpty else { return result }

        func assign(_ pick: (CGDirectDisplayID) -> [Int]) {
            for id in remaining {
                let hits = pick(id)
                guard hits.count == 1 else { continue }
                result[id] = free[hits[0]].service
                free.remove(at: hits[0])
                remaining.removeAll { $0 == id }
            }
        }

        assign { id in
            guard let location = PrivateAPI.displayLocation(id)?.lowercased() else { return [] }
            return free.indices.filter { index in
                guard let node = free[index].node?.lowercased() else { return false }
                return location.contains("/\(node)/") || location.hasSuffix("/\(node)")
            }
        }
        assign { id in
            free.indices.filter {
                free[$0].vendor == CGDisplayVendorNumber(id) && free[$0].product == CGDisplayModelNumber(id)
                    && free[$0].serial == CGDisplaySerialNumber(id)
            }
        }
        assign { id in
            free.indices.filter {
                free[$0].vendor == CGDisplayVendorNumber(id) && free[$0].product == CGDisplayModelNumber(id)
            }
        }
        if remaining.count == 1, free.count == 1 {
            result[remaining[0]] = free[0].service
        }
        return result
    }

    private static func pipeNode(above entry: io_registry_entry_t) -> String? {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0 ..< 24 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, "IOService", &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent

            var nameBuffer = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(current, &nameBuffer) == KERN_SUCCESS else { continue }
            let name = String(cString: nameBuffer)
            guard name.range(of: "^disp(ext)?[0-9]+$", options: .regularExpression) != nil else { continue }

            var locationBuffer = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetLocationInPlane(current, "IOService", &locationBuffer) == KERN_SUCCESS {
                return name + "@" + String(cString: locationBuffer)
            }
            return name
        }
        return nil
    }
}
