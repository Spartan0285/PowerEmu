import CoreGraphics

/// The single shape used for masked-desktop rendering and input routing.
enum HarmonyDesktopGeometry {
    static func path(windows: [CGRect], guestSize: CGSize, bounds: CGRect) -> CGPath {
        let path = CGMutablePath()
        guard guestSize.width > 0, guestSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return path }
        let sx = bounds.width / guestSize.width
        let sy = bounds.height / guestSize.height
        for window in windows where !window.isEmpty && !window.isInfinite && !window.isNull {
            let rect = CGRect(x: bounds.minX + window.minX * sx,
                              y: bounds.minY + (guestSize.height - window.maxY) * sy,
                              width: window.width * sx, height: window.height * sy)
            // Match the existing visual shape, scaled with the guest image.
            let rx = min(6 * sx, rect.width / 2)
            let ry = min(6 * sy, rect.height / 2)
            path.addRoundedRect(in: rect, cornerWidth: rx, cornerHeight: ry)
        }
        return path
    }
}
