import CoreGraphics

/*
 * Guest points to this Mac's points and back, for one guest screen.
 *
 * `scale` exists for a second guest screen that is not the same size as the
 * host screen it is shown on -- a 3200x2400 guest screen on a 1600x1200-point
 * Retina display is two guest pixels to the point, which is exactly one host
 * pixel.  The first screen is resized to its host screen when Harmony starts,
 * so there it is 1 and these are pure translations, as they always were.
 */
struct HarmonyCoordinates {
    let screen: CGRect
    let topInset: CGFloat
    var scale: CGFloat = 1
    func hostPoint(_ guest: CGPoint) -> CGPoint {
        CGPoint(x: screen.minX + guest.x * scale,
                y: screen.maxY - topInset - guest.y * scale)
    }
    func guestPoint(_ host: CGPoint) -> CGPoint {
        CGPoint(x: (host.x - screen.minX) / scale,
                y: (screen.maxY - topInset - host.y) / scale)
    }
    func hostRect(_ guest: CGRect) -> CGRect {
        CGRect(origin: hostPoint(CGPoint(x: guest.minX, y: guest.maxY)),
               size: CGSize(width: guest.width * scale, height: guest.height * scale))
    }
}
