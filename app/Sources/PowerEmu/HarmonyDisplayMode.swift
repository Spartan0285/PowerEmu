import AppKit
import CoreGraphics

/// A logical-pixel canvas. Firmware, NDRV and the GPU agree on a 64-pixel
/// aligned row width; surplus columns remain beyond the host screen, not scaled.
struct HarmonyDisplayMode {
    static func size(screen: CGRect, visible: CGRect) -> CGSize {
        let width = Int(screen.width.rounded())
        let topInset = max(0, screen.maxY - visible.maxY - 22)
        return CGSize(width: CGFloat((width + 63) & ~63), height: (screen.height - topInset).rounded())
    }

    /*
     * The same, for a screen that can say where its usable area really starts.
     *
     * Working it out from the menu bar -- everything above the usual 22 points
     * of it -- misses most of a notch.  On a 14-inch MacBook Pro the notch is
     * 33 points tall and the menu bar is drawn beside it, so that sum comes to
     * 12 and leaves the top 21 points of the guest's screen behind the notch
     * in fullscreen, which is where its menu bar lives.
     *
     * safeAreaInsets says it outright, so prefer it when the screen reports
     * one and keep the old reading for screens that do not.
     */
    static func size(screen: NSScreen) -> CGSize {
        let frame = screen.frame
        let inset: CGFloat
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
            inset = screen.safeAreaInsets.top
        } else {
            inset = max(0, frame.maxY - screen.visibleFrame.maxY - 22)
        }
        let width = Int(frame.width.rounded())
        return CGSize(width: CGFloat((width + 63) & ~63),
                      height: (frame.height - inset).rounded())
    }

    /// Whether this screen has a notch, and how tall it is in points.
    static func notch(on screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) { return screen.safeAreaInsets.top }
        return 0
    }

    /// Patch only the reserved mode in a private copy of our uncompressed PEF
    /// data section. The signed bundled driver and its code remain unchanged.
    static func driver(_ original: Data, size: CGSize) throws -> Data {
        enum InvalidDriver: Error { case format }
        guard original.count >= 40, original.prefix(12) == Data("Joy!peffpwpc".utf8),
              (640...4096).contains(Int(size.width)), (480...2048).contains(Int(size.height)),
              Int(size.width) % 64 == 0 else { throw InvalidDriver.format }
        func word(_ offset: Int) -> Int {
            original[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        let count = Int(original[32]) << 8 | Int(original[33])
        guard count > 0, count < 64, 40 + count * 28 <= original.count else { throw InvalidDriver.format }
        for section in 0..<count {
            let header = 40 + section * 28
            guard original[header + 24] == 1 else { continue }
            let offset = word(header + 20), length = word(header + 16)
            let mode = 0xd24 + 8 * 45
            guard length == word(header + 12), length >= mode + 8,
                  offset <= original.count, length <= original.count - offset,
                  word(offset + mode) == 1680, word(offset + mode + 4) == 1056 else { throw InvalidDriver.format }
            var copy = original
            for (at, value) in [(offset + mode, Int(size.width)), (offset + mode + 4, Int(size.height))] {
                for byte in 0..<4 { copy[at + byte] = UInt8((value >> (24 - byte * 8)) & 255) }
            }
            return copy
        }
        throw InvalidDriver.format
    }
}
