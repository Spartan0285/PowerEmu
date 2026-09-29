import AppKit
import IOSurface
import zlib

@main
struct HarmonyRegression {
    static func main() {
        // Host display origins can be negative, and Retina backing pixels
        // must never enter logical window/input placement arithmetic.
        for origin in [CGPoint.zero, CGPoint(x: -1710, y: 150)] {
            let map = HarmonyCoordinates(screen: CGRect(origin: origin, size: CGSize(width: 1710, height: 1107)), topInset: 15)
            for point in [CGPoint.zero, CGPoint(x: 1709, y: 1106), CGPoint(x: 412, y: 318)] {
                precondition(map.guestPoint(map.hostPoint(point)) == point, "coordinate round trip")
            }
            let rect = CGRect(x: 100, y: 60, width: 785, height: 443)
            precondition(map.hostRect(rect).size == rect.size, "one guest pixel per logical host point")
            precondition(map.guestPoint(CGPoint(x: map.hostRect(rect).minX, y: map.hostRect(rect).maxY)) == rect.origin)
        }
        let mode = HarmonyDisplayMode.size(screen: CGRect(x: 0, y: 0, width: 1710, height: 1107), visible: CGRect(x: 0, y: 0, width: 1710, height: 1074))
        precondition(mode == CGSize(width: 1728, height: 1096), "safe stride and host menu inset")
        if CommandLine.arguments.count > 1 {
            let original = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let patched = try! HarmonyDisplayMode.driver(original, size: mode)
            precondition(patched.count == original.count)
            let differences = zip(original, patched).filter { $0 != $1 }.count
            precondition(differences > 0 && differences <= 8, "patch only reserved mode dimensions")
            precondition((try? HarmonyDisplayMode.driver(Data(), size: mode)) == nil)
            precondition((try? HarmonyDisplayMode.driver(original, size: CGSize(width: 1710, height: 1107))) == nil, "reject unsafe row alignment")
        }
        let guest = CGSize(width: 1000, height: 800)
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
        let windows = [CGRect(x: 100, y: 100, width: 200, height: 200),
                       CGRect(x: 600, y: 100, width: 200, height: 200)]
        let mask = HarmonyDesktopGeometry.path(windows: windows, guestSize: guest, bounds: bounds)
        precondition(mask.contains(CGPoint(x: 100, y: 300)), "guest interior")
        precondition(!mask.contains(CGPoint(x: 225, y: 300)), "host hole between windows")
        precondition(!mask.contains(CGPoint(x: 50.1, y: 349.9)), "rounded corner passes through")
        precondition(!mask.contains(CGPoint(x: 100, y: 50)), "top-left origin conversion")
        precondition(HarmonyDesktopGeometry.path(windows: [], guestSize: guest, bounds: bounds).isEmpty)
        precondition(HarmonyDesktopGeometry.path(windows: windows, guestSize: .zero, bounds: bounds).isEmpty)
        // The screen can be letterboxed below the host menu bar. Input must
        // use the layer transform, not the full view's width and height.
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let screen = CALayer()
        screen.frame = CGRect(x: 100, y: 35, width: 500, height: 400)
        root.addSublayer(screen)
        precondition(mask.contains(screen.convert(CGPoint(x: 200, y: 335), from: root)))
        precondition(!mask.contains(screen.convert(CGPoint(x: 325, y: 335), from: root)))
        let overlap = HarmonyDesktopGeometry.path(windows: [windows[0], windows[0]], guestSize: guest, bounds: bounds)
        precondition(overlap.contains(CGPoint(x: 100, y: 300)), "overlap stays opaque")

        let props: [CFString: Any] = [kIOSurfaceWidth: 7, kIOSurfaceHeight: 5,
            kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: 64,
            kIOSurfacePixelFormat: 0x42475241]
        let staging = IOSurfaceCreate(props as CFDictionary)!
        IOSurfaceLock(staging, [], nil)
        let base = IOSurfaceGetBaseAddress(staging)
        for y in 0..<5 {
            for x in 0..<7 { base.storeBytes(of: UInt32(0xff000000 | (y << 8) | x), toByteOffset: y * 64 + x * 4, as: UInt32.self) }
        }
        IOSurfaceUnlock(staging, [], nil)
        let published = HarmonySurfaceSnapshot.copy(staging)!
        IOSurfaceLock(staging, [], nil)
        memset(base, 0x42, IOSurfaceGetAllocSize(staging))
        IOSurfaceUnlock(staging, [], nil)
        IOSurfaceLock(published, .readOnly, nil)
        let copy = IOSurfaceGetBaseAddress(published), stride = IOSurfaceGetBytesPerRow(published)
        for y in 0..<5 {
            for x in 0..<7 {
                precondition(copy.load(fromByteOffset: y * stride + x * 4, as: UInt32.self) == UInt32(0xff000000 | (y << 8) | x), "published frame changed after producer reuse")
            }
        }
        IOSurfaceUnlock(published, .readOnly, nil)
        var packet = Data("42 2 1\n".utf8)
        packet.append(contentsOf: [255, 0, 0, 255, 0, 255, 0, 255])
        let decoded = HarmonyWindowFrame.decode(packet)!
        packet.resetBytes(in: 0..<packet.count)
        precondition(decoded.id == 42 && decoded.image.width == 2 && decoded.image.height == 1)
        precondition((decoded.image.dataProvider!.data! as Data).first == 255, "capture must own immutable bytes")
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255]
        var packed = [UInt8](repeating: 0, count: Int(compressBound(uLong(rgba.count))))
        var packedCount = uLongf(packed.count)
        precondition(compress2(&packed, &packedCount, rgba, uLong(rgba.count), 1) == Z_OK)
        var compressed = Data("42 2 1 1\n".utf8)
        compressed.append(contentsOf: packed.prefix(Int(packedCount)))
        precondition(HarmonyWindowFrame.decode(compressed)?.image.width == 2)
        var sequenced = Data("42 2 1 1 7123\n".utf8)
        sequenced.append(contentsOf: packed.prefix(Int(packedCount)))
        precondition(HarmonyWindowFrame.decode(sequenced)?.sequence == 7123)
        compressed.removeLast(2)
        precondition(HarmonyWindowFrame.decode(compressed) == nil, "reject truncated compressed stream")
        for invalid in ["42 0 0\n", "42 -1 2\n", "42 4097 1\n", "42 2 1\nshort", "42 1 1", "-1 1 1\n1234"] {
            precondition(HarmonyWindowFrame.decode(Data(invalid.utf8)) == nil, "reject malformed capture")
        }
        // Cross-language fixtures produced by guest/tools/pepixelpackcheck.c.
        if CommandLine.arguments.count > 2 {
            let fixtures = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            var offset = 0, cases = 0
            func integer() -> Int {
                precondition(offset + 4 <= fixtures.count)
                let value = fixtures[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
                offset += 4; return value
            }
            while offset < fixtures.count {
                let count = integer(), length = integer()
                let original = fixtures.subdata(in: offset..<offset+count*4); offset += count*4
                var encoded = Data("77 \(count) 1 3 91\n".utf8)
                encoded.append(fixtures.subdata(in: offset..<offset+length)); offset += length
                let image = HarmonyWindowFrame.decode(encoded)!
                precondition(image.sequence == 91 && (image.image.dataProvider!.data! as Data) == original)
                var truncated = encoded; truncated.removeLast()
                precondition(HarmonyWindowFrame.decode(truncated) == nil)
                encoded.append(0)
                precondition(HarmonyWindowFrame.decode(encoded) == nil, "reject trailing pixel packet")
                cases += 1
            }
            precondition(cases == 600)
            print("PASS: 600 guest pixel-packet fixtures, exact RGBA, truncation/trailing rejection")
        }
        for payload: [UInt8] in [[], [0x80], [0x81,1,2,3,4], [0,1,2,3], [1,1,2,3,4]] {
            var malformed = Data("77 1 1 3 1\n".utf8); malformed.append(contentsOf: payload)
            precondition(HarmonyWindowFrame.decode(malformed) == nil)
        }
        print("PASS: mask holes, rounded corners, scaling, letterboxing, empty geometry, overlap, immutable frame/stride")
        print("PASS: complete-window frame dimensions, immutable pixels, malformed and truncated payload rejection")
    }
}
