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
}
