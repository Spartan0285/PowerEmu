import CoreGraphics

/// Native Harmony must always leave a visible host pointer. Guest cursor-hide
/// shapes are meaningful on the guest desktop, but not across host windows.
enum HarmonyCursorImage {
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
