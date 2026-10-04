import CoreGraphics

/*
 * Guest points to this Mac's points and back.
 *
 * Every Harmony window's place on screen, every click inside one and every
 * drag that ends somewhere new goes through this, in both directions.  A sign
 * or a scale wrong here is a window that lands somewhere else, or springs
 * back -- which is exactly what a second screen did until it was given a
 * scale.  So both directions are checked against each other.
 *
 *   swiftc -o /tmp/harmonycoords tests/HarmonyCoordinates/main.swift \
 *       app/Sources/PowerEmu/HarmonyCoordinates.swift && /tmp/harmonycoords
 */

func near(_ a: CGFloat, _ b: CGFloat, _ what: String) {
    assert(abs(a - b) < 0.001, "\(what): \(a) != \(b)")
}
func near(_ a: CGPoint, _ b: CGPoint, _ what: String) {
    near(a.x, b.x, what + ".x"); near(a.y, b.y, what + ".y")
}

/* The first screen: the guest is resized to it, so this is a translation. */
let first = HarmonyCoordinates(screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
                               topInset: 25)
near(first.hostPoint(CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 957), "guest origin")
near(first.guestPoint(first.hostPoint(CGPoint(x: 300, y: 200))),
     CGPoint(x: 300, y: 200), "round trip")
/* A guest rectangle is anchored by its top-left corner. */
let r = first.hostRect(CGRect(x: 100, y: 50, width: 400, height: 300))
near(r.minX, 100, "rect x")
near(r.maxY, 907, "rect top")          // 982 - 25 - 50
near(r.width, 400, "rect width")

/*
 * The second screen, a 3200x2400 guest screen on a 1600x1200-point display:
 * two guest pixels to the point, which on that display is one host pixel.
 * Its host screen sits to the right of the first, at x = 1512.
 */
let second = HarmonyCoordinates(screen: CGRect(x: 1512, y: 0, width: 1600, height: 1200),
                                topInset: 0, scale: 0.5)
near(second.hostPoint(CGPoint(x: 0, y: 0)), CGPoint(x: 1512, y: 1200), "second origin")
/* The far corner of the guest screen is the far corner of the host screen. */
near(second.hostPoint(CGPoint(x: 3200, y: 2400)), CGPoint(x: 3112, y: 0), "second far corner")
near(second.guestPoint(second.hostPoint(CGPoint(x: 2000, y: 1600))),
     CGPoint(x: 2000, y: 1600), "second round trip")
/* A window is drawn at half its guest size, so it covers the same part of
 * the screen it covers in the guest. */
let w = second.hostRect(CGRect(x: 400, y: 200, width: 800, height: 600))
near(w.width, 400, "second width")
near(w.height, 300, "second height")
near(w.minX, 1712, "second x")         // 1512 + 400/2
near(w.maxY, 1100, "second top")       // 1200 - 200/2

/* A drop converted back gives the guest point it was drawn from: this is the
 * round trip that decides whether a dragged window stays put. */
for guest in [CGPoint(x: 0, y: 0), CGPoint(x: 1234, y: 567), CGPoint(x: 3199, y: 2399)] {
    near(second.guestPoint(second.hostPoint(guest)), guest, "drop at \(guest)")
}

/* Scale defaults to 1, so every existing caller is unchanged. */
let plain = HarmonyCoordinates(screen: CGRect(x: 7, y: 9, width: 100, height: 100), topInset: 3)
near(plain.scale, 1, "default scale")
near(plain.hostPoint(CGPoint(x: 10, y: 10)), CGPoint(x: 17, y: 96), "default mapping")

print("HarmonyCoordinates: ok")
