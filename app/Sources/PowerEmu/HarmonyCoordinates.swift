import CoreGraphics

struct HarmonyCoordinates {
    let screen: CGRect
    let topInset: CGFloat
    func hostPoint(_ guest: CGPoint) -> CGPoint {
        CGPoint(x: screen.minX + guest.x, y: screen.maxY - topInset - guest.y)
    }
    func guestPoint(_ host: CGPoint) -> CGPoint {
        CGPoint(x: host.x - screen.minX, y: screen.maxY - topInset - host.y)
    }
    func hostRect(_ guest: CGRect) -> CGRect {
        CGRect(origin: hostPoint(CGPoint(x: guest.minX, y: guest.maxY)), size: guest.size)
    }
}
