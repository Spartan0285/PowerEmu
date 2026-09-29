import Foundation
import CoreGraphics
import zlib

/// A complete immutable RGBA window image, never a crop of the guest desktop.
struct HarmonyWindowFrame {
    let id: Int
    let sequence: Int
    let image: CGImage

    static func decode(_ data: Data, base: Self? = nil) -> Self? {
        guard let newline = data.prefix(80).firstIndex(of: 10) else { return nil }
        let tokens = String(decoding: data[..<newline], as: UTF8.self).split(separator: " ")
        let fields = tokens.compactMap { Int($0) }
        guard fields.count == tokens.count, (3...5).contains(fields.count), fields[0] > 0,
              (1...4096).contains(fields[1]), (1...4096).contains(fields[2]) else { return nil }
        let w = fields[1], h = fields[2]
        var bytes = Data(data[data.index(after: newline)...])
        let encoding = fields.count >= 4 ? fields[3] : 0
        guard encoding == 0 || encoding == 1 || encoding == 3 || encoding == 4 else { return nil }
        if encoding == 1 {
            var unpacked = Data(count: w * h * 4)
            var size = uLongf(unpacked.count)
            let result = unpacked.withUnsafeMutableBytes { out in
                bytes.withUnsafeBytes { source in
                    uncompress(out.bindMemory(to: Bytef.self).baseAddress!, &size,
                               source.bindMemory(to: Bytef.self).baseAddress, uLong(bytes.count))
                }
            }
            guard result == Z_OK, size == unpacked.count else { return nil }
            bytes = unpacked
        }
        if encoding == 4 {
            guard fields.count == 5, let base, base.id == fields[0],
                  base.sequence > 0, base.sequence < fields[4],
                  base.image.width == w, base.image.height == h,
                  let unpacked = unpackTiles(bytes, width: w, height: h, base: base) else { return nil }
            bytes = unpacked
        }
        if encoding == 3 {
            guard let unpacked = unpackPixels(bytes, count: w * h) else { return nil }
            bytes = unpacked
        }
        guard bytes.count == w * h * 4, let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return Self(id: fields[0], sequence: fields.count == 5 ? fields[4] : 0, image: image)
    }

    /// Encoding 4: zlib-compressed tile stream prefixed with its raw length.
    /// Rebuild a separate image; never mutate the base provider's pixels.
    private static func unpackTiles(_ packed: Data, width: Int, height: Int, base: Self) -> Data? {
        func word(_ data: Data, _ offset: Int) -> Int {
            (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
        }
        guard packed.count > 4 else { return nil }
        let columns = (width + 31) / 32, rows = (height + 31) / 32
        let length = word(packed, 0)
        guard length >= 12, length <= width * height * 4 + columns * rows * 4 + 8 else { return nil }
        var stream = Data(count: length)
        var actual = uLongf(length)
        var consumed = uLong(packed.count - 4)
        let result = stream.withUnsafeMutableBytes { out in
            packed.withUnsafeBytes { source in
                uncompress2(out.bindMemory(to: Bytef.self).baseAddress!, &actual,
                            source.bindMemory(to: Bytef.self).baseAddress!.advanced(by: 4), &consumed)
            }
        }
        guard result == Z_OK, actual == length, consumed == packed.count - 4, word(stream, 0) == base.sequence,
              let original = base.image.dataProvider?.data, CFDataGetLength(original) == width * height * 4 else { return nil }
        let count = word(stream, 4)
        guard count > 0, count <= columns * rows else { return nil }
        var output = Data(bytes: CFDataGetBytePtr(original)!, count: CFDataGetLength(original))
        var offset = 8, previous = -1
        for _ in 0..<count {
            guard stream.count - offset >= 4 else { return nil }
            let tile = word(stream, offset); offset += 4
            guard tile > previous, tile < columns * rows else { return nil }
            previous = tile
            let x = tile % columns * 32, y = tile / columns * 32
            let tw = min(32, width - x), th = min(32, height - y)
            guard stream.count - offset >= tw * th * 4 else { return nil }
            output.withUnsafeMutableBytes { dest in
                stream.withUnsafeBytes { source in
                    for row in 0..<th {
                        dest.baseAddress!.advanced(by: ((y + row) * width + x) * 4)
                            .copyMemory(from: source.baseAddress!.advanced(by: offset + row * tw * 4), byteCount: tw * 4)
                    }
                }
            }
            offset += tw * th * 4
        }
        guard offset == stream.count else { return nil }
        return output
    }

    /// Encoding 3: independent runs/literals of four-byte RGBA pixels.
    /// Require an exact image and exact payload consumption; never accept a
    /// partial frame, oversized run, trailing bytes, or missing pixel bytes.
    private static func unpackPixels(_ packed: Data, count: Int) -> Data? {
        var result = Data(count: count * 4)
        let valid = packed.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            result.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                guard let src = source.baseAddress, let dst = destination.baseAddress else { return false }
                var input = 0, output = 0
                while input < source.count {
                    let control = source[input]; input += 1
                    let length = Int(control & 127) + 1
                    guard length <= count - output else { return false }
                    if control & 128 != 0 {
                        guard source.count - input >= 4 else { return false }
                        for pixel in 0..<length {
                            dst.advanced(by: (output + pixel) * 4).copyMemory(from: src.advanced(by: input), byteCount: 4)
                        }
                        input += 4
                    } else {
                        guard source.count - input >= length * 4 else { return false }
                        dst.advanced(by: output * 4).copyMemory(from: src.advanced(by: input), byteCount: length * 4)
                        input += length * 4
                    }
                    output += length
                }
                return output == count
            }
        }
        return valid ? result : nil
    }

}
