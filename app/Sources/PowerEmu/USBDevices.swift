import Foundation
import IOKit
import IOKit.usb

/// A USB device plugged into this Mac, which QEMU's usb-host can hand to a
/// virtual Mac.  macOS keeps devices its own drivers use (keyboards, mice,
/// disks), so those usually can't be taken; others (scanners, MIDI or
/// serial adapters, game pads, vendor gadgets) usually can.
struct HostUSBDevice: Hashable, Identifiable {
    let vendor: Int
    let product: Int
    let name: String
    let location: UInt32
    var id: String { String(format: "usb-%04x-%04x-%08x", vendor, product, location) }

    /// Devices on this Mac's USB ports, hubs left out.
    static func list() -> [HostUSBDevice] {
        var out: [HostUSBDevice] = []
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS else {
            return out
        }
        defer { IOObjectRelease(iter) }
        while case let dev = IOIteratorNext(iter), dev != 0 {
            defer { IOObjectRelease(dev) }
            func prop(_ k: String) -> Any? {
                IORegistryEntryCreateCFProperty(dev, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let v = prop("idVendor") as? Int, let p = prop("idProduct") as? Int else { continue }
            if (prop("bDeviceClass") as? Int) == 9 { continue }             // hubs
            let product = prop("USB Product Name") as? String ?? prop("kUSBProductString") as? String
            let vendor = prop("USB Vendor Name") as? String ?? prop("kUSBVendorString") as? String
            let name = [vendor, product].compactMap { $0 }.joined(separator: " ")
            let loc = (prop("locationID") as? UInt32) ?? UInt32(truncatingIfNeeded: (prop("locationID") as? Int) ?? 0)
            out.append(HostUSBDevice(vendor: v, product: p,
                                     name: name.isEmpty ? String(format: "USB device %04x:%04x", v, p) : name,
                                     location: loc))
        }
        return out.sorted { $0.name < $1.name }
    }
}
