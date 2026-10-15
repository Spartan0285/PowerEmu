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

    /*
     * The usable area of a screen at its own exact size.
     *
     * size(screen:) rounds the width up to a multiple of 64 because the
     * Harmony reserved mode needs that stride.  A *startup* resolution does
     * not: it is just the mode the guest boots in, and rounding it made the
     * entry named after a display not match that display -- a 1680 x 1050
     * Cinema Display was offered as "Cinema Display -- 1728 x 1050", which is
     * the one thing the entry exists to get right.
     */
    static func exactSize(screen: NSScreen) -> CGSize {
        let frame = screen.frame
        let inset: CGFloat
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
            inset = screen.safeAreaInsets.top
        } else {
            inset = max(0, frame.maxY - screen.visibleFrame.maxY - 22)
        }
        return CGSize(width: frame.width.rounded(), height: (frame.height - inset).rounded())
    }

    /// Whether this screen has a notch, and how tall it is in points.
    static func notch(on screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) { return screen.safeAreaInsets.top }
        return 0
    }

    /// Patch the reserved modes in a private copy of our uncompressed PEF
    /// data section. The signed bundled driver and its code remain unchanged.
    ///
    /// One mode per host screen, up to two.
    ///
    /// There used to be one, taken from NSScreen.main when the machine
    /// started, and that is as many host screens as Harmony could be used on.
    /// With a 1710-point built-in display and a 1680 x 1050 Cinema Display
    /// the guest was given 1728 x 1074 and nothing else, so asking for
    /// Harmony with the window on the Cinema Display asked the guest for
    /// 1728 x 1050 -- a mode it had never heard of -- and the attempt ended
    /// in "Harmony display mode is unavailable".
    ///
    /// The second mode goes in entry 47, which ships as 1920 x 1200 and is an
    /// exact duplicate of entry 46: overwriting it costs the guest nothing,
    /// and the duplicate is checked for rather than assumed, so a driver that
    /// stops being laid out this way is left alone instead of corrupted.
    static func driver(_ original: Data, sizes: [CGSize]) throws -> Data {
        enum InvalidDriver: Error { case format }
        guard let first = sizes.first else { throw InvalidDriver.format }
        var out = try driver(original, size: first)
        // Only a second, genuinely different size is worth a slot.
        guard let second = sizes.dropFirst().first(where: { $0 != first }) else { return out }
        guard (640...4096).contains(Int(second.width)), (480...2048).contains(Int(second.height)),
              Int(second.width) % 64 == 0 else { return out }
        func word(_ d: Data, _ offset: Int) -> Int {
            d[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        let count = Int(out[32]) << 8 | Int(out[33])
        for section in 0..<count {
            let header = 40 + section * 28
            guard out[header + 24] == 1 else { continue }
            let offset = word(out, header + 20), length = word(out, header + 16)
            let spare = 0xd24 + 8 * 47, twin = 0xd24 + 8 * 46
            // The spare must still be the duplicate of its neighbour that it
            // ships as; anything else and the second mode is simply not added.
            guard length >= spare + 8, offset <= out.count, length <= out.count - offset,
                  word(out, offset + spare) == 1920, word(out, offset + spare + 4) == 1200,
                  word(out, offset + twin) == 1920, word(out, offset + twin + 4) == 1200
            else { return out }
            for (at, value) in [(offset + spare, Int(second.width)),
                                (offset + spare + 4, Int(second.height))] {
                for byte in 0..<4 { out[at + byte] = UInt8((value >> (24 - byte * 8)) & 255) }
            }
            return out
        }
        return out
    }

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
