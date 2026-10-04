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
     * The pixel size of the screen the second guest screen would land on,
     * when this Mac has one to land on.  Offered in the second screen's menu
     * so the guest can be told to match the monitor it is actually shown on,
     * rather than the reader working the number out themselves.
     *
     * Backing-store pixels, not points: the guest draws pixels, and a guest
     * mode matching the panel is what avoids scaling.
     */
    var secondScreenPixelSize: CGSize? {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return nil }
        let s = screens[1]
        let f = s.frame
        return CGSize(width: (f.width * s.backingScaleFactor).rounded(),
                      height: (f.height * s.backingScaleFactor).rounded())
    }
}
