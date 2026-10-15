import CoreGraphics
func image(_ alpha: [UInt8], opaque: Bool = false) -> CGImage {
    let bytes = alpha.flatMap { [UInt8(80), UInt8(160), UInt8(200), $0] }
    return CGImage(width: alpha.count, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: alpha.count * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.last.rawValue),
        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
import Foundation
precondition(!HarmonyCursorImage.hasVisiblePixels(image([0, 0, 0, 0])))
precondition(HarmonyCursorImage.hasVisiblePixels(image([0, 0, 255, 0])))
precondition(HarmonyCursorImage.hasVisiblePixels(image([0, 1, 0, 0])))
precondition(HarmonyCursorImage.hasVisiblePixels(image([0, 0], opaque: true)))
print("PASS: invisible cursor fallback; opaque, translucent and no-alpha cursor shapes")
