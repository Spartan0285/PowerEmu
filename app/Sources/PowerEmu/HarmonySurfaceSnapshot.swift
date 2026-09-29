import Foundation
import IOSurface

/// Published frames outlive the CPU callback: Core Animation reads later.
/// Call while holding the producer's lock, then never write the result again.
enum HarmonySurfaceSnapshot {
    static func copy(_ source: IOSurfaceRef) -> IOSurfaceRef? {
        let width = IOSurfaceGetWidth(source), height = IOSurfaceGetHeight(source)
        guard width > 0, height > 0 else { return nil }
        let stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width, kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: stride,
            kIOSurfacePixelFormat: 0x42475241
        ]
        guard let target = IOSurfaceCreate(properties as CFDictionary) else { return nil }
        IOSurfaceLock(source, .readOnly, nil)
        IOSurfaceLock(target, [], nil)
        defer {
            IOSurfaceUnlock(target, [], nil)
            IOSurfaceUnlock(source, .readOnly, nil)
        }
        let src = IOSurfaceGetBaseAddress(source)
        let dst = IOSurfaceGetBaseAddress(target)
        let sourceStride = IOSurfaceGetBytesPerRow(source)
        for row in 0..<height {
            memcpy(dst + row * stride, src + row * sourceStride, width * 4)
        }
        return target
    }
}
