import CoreGraphics
import Foundation

/// Native Harmony must always leave a visible host pointer. Guest cursor-hide
/// shapes are meaningful on the guest desktop, but not across host windows.
enum HarmonyCursorImage {
    /// Classic Mac cursors (Word's I-beam, its margin arrow) invert what is
    /// under them. The WindowServer stores those pixels with zero alpha and
    /// non-zero colour; neither the card nor an NSCursor can invert, so they
    /// came out fully transparent and Harmony fell back to the arrow. Draw
    /// them as Tiger shows them on a white page: black, with a thin white
    /// edge so they stay visible on dark backgrounds.
    /// `pixels` is big-endian ARGB, `rowBytes` per row.
    static func resolvingInvert(_ pixels: Data, width w: Int, height h: Int, rowBytes: Int) -> Data {
        var out = [UInt8](pixels)
        guard out.count >= rowBytes * h else { return pixels }
        func at(_ x: Int, _ y: Int) -> Int { y * rowBytes + x * 4 }
        var invert = [Bool](repeating: false, count: w * h)
        var any = false
        for y in 0..<h { for x in 0..<w {
            let i = at(x, y)
            if out[i] == 0 && (out[i + 1] | out[i + 2] | out[i + 3]) != 0 { invert[y * w + x] = true; any = true }
        } }
        guard any else { return pixels }
        for y in 0..<h { for x in 0..<w where invert[y * w + x] {
            let i = at(x, y); out[i] = 0xFF; out[i + 1] = 0; out[i + 2] = 0; out[i + 3] = 0
        } }
        for y in 0..<h { for x in 0..<w where !invert[y * w + x] {
            let i = at(x, y)
            guard out[i] == 0 else { continue }
            let near = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].contains { nx, ny in
                nx >= 0 && ny >= 0 && nx < w && ny < h && invert[ny * w + nx]
            }
            if near { out[i] = 0xFF; out[i + 1] = 0xFF; out[i + 2] = 0xFF; out[i + 3] = 0xFF }
        } }
        return Data(out)
    }
    static func hasVisiblePixels(_ image: CGImage) -> Bool {
        guard image.width > 0, image.height > 0, image.width <= 1024, image.height <= 1024 else { return false }
        var alpha = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return alpha.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return stride(from: 3, to: storage.count, by: 4).contains { storage[$0] != 0 }
        }
    }
}
