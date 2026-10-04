import SwiftUI
import AppKit

/*
 * How many screens this Mac has, as something a view can watch.
 *
 * A second guest screen is always offered; what changes with the screen count
 * is how it is *shown*.  With two host screens each guest screen gets its own
 * window, one per screen.  With one, a second window would simply cover the
 * first, so the two share the machine's window side by side instead -- see
 * CombinedScreensView.
 *
 * Screens come and go while the app is running (a monitor is plugged in, a
 * laptop is docked, a display sleeps), and AppKit says so with
 * didChangeScreenParameters.  Without watching for that, the setting would be
 * whatever was true when the window opened.
 */
@MainActor
final class HostScreens: ObservableObject {
    static let shared = HostScreens()

    @Published private(set) var count: Int = NSScreen.screens.count

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = NSScreen.screens.count
                if now != self.count { self.count = now }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /* Whether a second guest screen can be offered at all. */
    var canUseTwo: Bool { count > 1 }

    /*
     * The second host display's size, as choices for the guest's second
     * screen.  Offered in that screen's menu so the guest can be told to match
     * the monitor it is shown on, rather than the reader working it out.
     *
     * A Retina display is two choices, not one, and the difference matters
     * more than it looks.  Mac OS X has no notion of a Retina screen: it draws
     * one pixel per pixel, whatever the display.  So the panel's own pixel
     * count is the sharpest a guest screen can be -- and on a 2x display it
     * also makes every window, menu and letter half the size it should be.
     * The point size is the one that comes out the right size, each guest
     * pixel drawn as a 2x2 block.
     *
     * The point size is first because it is what Harmony already does with
     * the first screen (HarmonyDisplayMode takes screen.frame, which is
     * points), and because a second screen set in points maps 1:1 in Harmony
     * -- windows the same size on both screens, and the finest pointer
     * resolution, since a host pixel is then half a guest pixel rather than
     * two of them.
     */
    var secondScreenSizes: [(size: CGSize, note: String)] {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return [] }
        let s = screens[1]
        let f = s.frame
        let points = CGSize(width: f.width.rounded(), height: f.height.rounded())
        let pixels = CGSize(width: (f.width * s.backingScaleFactor).rounded(),
                            height: (f.height * s.backingScaleFactor).rounded())
        if pixels == points {
            return [(points, "this Mac\u{2019}s second screen")]
        }
        return [(points, "this Mac\u{2019}s second screen"),
                (pixels, "that screen\u{2019}s full detail \u{2014} everything appears half size")]
    }
}
