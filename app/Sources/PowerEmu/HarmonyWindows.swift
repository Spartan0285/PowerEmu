import AppKit
import IOSurface
import ImageIO
import UniformTypeIdentifiers

/// POWEREMU_HARMONY_DEBUG=1: the pointer mapping, written to a plain file so it
/// can be read from outside the app (the system log does not carry it).
let harmonyDebugFile: FileHandle? = {
    guard ProcessInfo.processInfo.environment["POWEREMU_HARMONY_DEBUG"] != nil else { return nil }
    let path = "/tmp/poweremu-harmony.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

func harmonyDebug(_ s: String) {
    guard let f = harmonyDebugFile else { return }
    f.write(Data((s + "\n").utf8))
}

/// Rootless ("Coherence") Harmony: each of the guest's windows is shown as a
/// real macOS window, so this Mac's own WindowServer gives them native
/// stacking, focus and dragging against this Mac's windows -- rather than the
/// whole guest screen being one masked layer.
///
/// The guest reports each window's id and rectangle (the tools' WINDOWS
/// message); the manager keeps one `HarmonyProxy` window per id, textured with
/// that window's part of the shared guest frame.  A click raises the real
/// guest window (RAISE), and dragging a proxy moves the guest window in step
/// (MOVEWINDOW) -- the writeup's coordinate injection.
@MainActor
final class HarmonyWindowManager: NSObject, NSWindowDelegate {
    /// Send a point/button/keys to the guest, and raise/move a guest window.
    var sendPoint: ((Int, Int) -> Void)?
    var sendButton: ((Int32, Bool) -> Void)?
    var sendScroll: ((Int32) -> Void)?
    /// Take a guest window back out of the guest's Dock.
    var unminimize: ((Int, Int) -> Void)?
    /// The guest's minimised windows, as last reported.
    var minimizedEntries: [(pid: Int, index: Int, title: String)] = []
    var raiseWindow: ((Int) -> Void)?
    /// Raise a window *and* its application, for the capture pass only.
    var raiseWindowHard: ((Int) -> Void)?
    var raiseWindowAt: ((Int, Int, Int) -> Void)?
    var moveWindow: ((Int, Int, Int) -> Void)?
    var moveWindowDrag: ((Int, Int, Int, Int, Int) -> Void)?
    /// Keys from whichever proxy is focused go to the guest through here (the
    /// view's own key handling).
    var forwardKey: ((NSEvent) -> Void)?

    private var proxies: [Int: HarmonyProxy] = [:]
    /// The guest's own menu bar, shown above everything at its 1:1 place, so
    /// the focused guest application's menus are the ones on offer.  Its menus
    /// open as ordinary guest windows, which become proxies like any other.
    private var menuBar: HarmonyProxy?
    /*
     * Every window is drawn from its own copy of its pixels rather than from
     * the shared screen.
     *
     * All the guest's windows live in one framebuffer, so a window's rectangle
     * in it holds whatever is drawn on top -- and while the window above is
     * being dragged away, the one below keeps showing the dragged window's old
     * pixels until the guest repaints, which looks like the window is smeared
     * across its neighbour.  A window can only be copied cleanly while nothing
     * covers it; since the guest's stacking now follows this Mac's, the
     * front-most window is always clear and is refreshed every frame, while a
     * covered one keeps the last clean copy of itself.
     */
    /// Two surfaces per window, written alternately.  Writing new pixels into
    /// the same surface and handing it back to the layer changes nothing that
    /// CoreAnimation can see -- the value it already holds is the same object --
    /// so the window sat frozen showing whatever was in it the first time.
    private final class WindowCopy {
        var surfaces: [IOSurfaceRef] = []
        var back = 0
        /// The last copy that was actually drawn into.  A window being resized
        /// gets new, empty surfaces; showing those would flash the desktop, so
        /// the previous picture is kept on screen (stretched a little) until
        /// the guest has painted the window at its new size.
        var lastGood: IOSurfaceRef?
        var front: IOSurfaceRef? { surfaces.isEmpty ? nil : surfaces[1 - back] }
    }
    private var copies: [Int: WindowCopy] = [:]
    /// Which copies were taken with nothing covering the window -- the others
    /// are blank or hold a neighbour's pixels and are waiting to be retaken.
    private var cleanSnapshots: Set<Int> = []
    private var capDebugTick = 0
    /// Windows seen for the first time, and how many reports ago.  A window is
    /// not copied until the guest has had time to paint it.
    private var fresh: [Int: Int] = [:]
    /// Where each window was last seen, to notice it moving.
    private var lastRect: [Int: CGRect] = [:]
    /// Whether each window was covered at the last report.
    private var wasCovered: [Int: Bool] = [:]
    /// The guest window that has the focus, straight from the guest.  The
    /// window list's own order cannot say: it is grouped by connection, so an
    /// application's windows come out next to each other even when another
    /// application's windows sit between them.
    var focusedGuestWindow = 0 {
        didSet {
            guard focusedGuestWindow != oldValue else { return }
            /*
             * Wait for the guest to actually draw before copying it.
             *
             * The guest says which window is in front the moment it is asked to
             * raise one -- before it has repainted.  Copying then stores the
             * window that *was* in front as this one's picture, which is the
             * smearing between windows.  Counting reports instead was both
             * wrong and slow: reports keep coming whether the guest has drawn
             * anything or not, so a quarter of a second was spent waiting and
             * the answer still was not guaranteed.  Frames only arrive when the
             * guest has actually painted something, so a couple of frames is
             * both the right thing to wait for and far quicker.
             */
            framesSinceFocus = 0
        }
    }
    /// Frames the guest has drawn since the front window changed.
    private var framesSinceFocus = 99
    /// How often the capture pass has failed to get a window to the front.
    private var captureMisses: [Int: Int] = [:]
    /// Whether the second, once-everything-has-settled pass has been done.
    private var didSettleCapture = false
    /// When the window at the head of the queue was first raised.
    private var captureBegan = Date()
    /// Windows the pass could not get to the front; not tried again, or it
    /// would queue them afresh on every report for the rest of the session.
    private var gaveUp = Set<Int>()
    /// Windows that have left the guest's list, and when: see below.
    private var vanished: [Int: Date] = [:]
    /*
     * Taking a clean copy of a window needs more than nothing covering it: the
     * framebuffer only changes where the guest draws, so a window that was
     * covered a moment ago still holds the other window's pixels until it is
     * repainted.  Raising a window makes the guest repaint it, so on the way
     * into Harmony each window is brought to the front in turn, copied, and the
     * window that was in front is put back.
     */
    private var captureQueue: [Int] = []
    private var captureTicks = 0
    private var captureRestore: Int?
    private(set) var capturing = false
    /// The capture pass waits for the guest's windows to settle: firing while
    /// they are still opening copies the wrong ones.
    private var settledIds: [Int] = []
    private var settledFor = 0
    private var capturedThisSession = false
    private var retryingMove = false
    private var order: [Int] = []                     // front-most first, as reported
    private var stack: [(id: Int, rect: CGRect, visible: CGRect)] = []  // as the guest last reported
    private weak var surface: AnyObject?              // the current IOSurface (as AnyObject)
    private var guestSize = CGSize(width: 1, height: 1)
    /// The guest screen's origin and scale on this Mac's screen.
    private var screenFrame = CGRect.zero
    /// This Mac's menu bar height, and the guest's -- to bottom-align them.
    var hostMenuBar: CGFloat = 0
    private var guestMenuBar: CGFloat = 22
    private(set) var active = false

    /// One uniform scale (guest width -> screen width).  This is exact only
    /// while the guest's aspect matches the screen's -- otherwise the vertical
    /// drifts (worst at the top).  Harmony switches the guest to a host-aspect
    /// mode (e.g. 1680x1088 for a 1710x1107 screen) on entry, so the same
    /// factor holds in both axes and clicks land where they are shown.
    private var scale: CGFloat { guestSize.width > 0 ? screenFrame.width / guestSize.width : 1 }
    /// How far below the top of the screen the guest starts, so its menu bar's
    /// bottom lines up with this Mac's taller menu bar.
    private var offsetY: CGFloat { max(0, hostMenuBar - guestMenuBar * scale) }

    func setActive(_ on: Bool, screenFrame: CGRect, guestSize: CGSize, hostMenuBar: CGFloat) {
        active = on
        self.screenFrame = screenFrame
        self.guestSize = guestSize
        self.hostMenuBar = hostMenuBar
        if on {
            startPointerTracking()
        } else {
            stopPointerTracking()
            for p in proxies.values { p.orderOut(nil) }; proxies = [:]; order = []
            menuBar?.orderOut(nil); menuBar = nil
            copies = [:]; cleanSnapshots = []; fresh = [:]; lastRect = [:]; wasCovered = [:]
            capturedThisSession = false; capturing = false; didSettleCapture = false
            gaveUp.removeAll(); captureMisses.removeAll()
            captureQueue = []; settledIds = []; settledFor = 0
        }
    }

    // MARK: the guest's pointer follows this Mac's

    private var pointerMonitors: [Any] = []
    /// Set while a proxy's title bar is being dragged: the guest's pointer must
    /// stay where it is then, so the guest does not start dragging its own
    /// window as well (the window is moved once, on drop).
    var suspendPointerTracking = false

    /// The guest's pointer has to follow this Mac's wherever it goes, not only
    /// when a proxy is clicked -- otherwise it stays where the last click left
    /// it, hover does nothing, and the drawn pointer sits somewhere stale.
    private func startPointerTracking() {
        stopPointerTracking()
        let follow: @Sendable (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let s = self, s.active, !s.suspendPointerTracking else { return }
                s.sendPointAtCursor()
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: follow) {
            pointerMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged],
            handler: { e in follow(e); return e }) {
            pointerMonitors.append(l)
        }
    }

    private func stopPointerTracking() {
        for m in pointerMonitors { NSEvent.removeMonitor(m) }
        pointerMonitors = []
        suspendPointerTracking = false
    }

    func setScreen(_ screenFrame: CGRect, guestSize: CGSize) {
        self.screenFrame = screenFrame
        self.guestSize = guestSize
    }

    /// A new frame from the guest: refresh the windows that can be read.
    /// Content used to be copied only when the guest reported its window
    /// positions, which tied how smoothly a window redraws to how often that
    /// report is sent -- so the report could not be slowed down to save the
    /// guest's time without making everything stutter.
    func refreshLiveCopies() {
        /*
         * The capture pass no longer stops this.  It raises a window so it can
         * be read whole -- which makes that window the one in front, so this
         * copies exactly the window the pass wants anyway.  Blocking on it
         * stopped every window from redrawing for a second and a half per
         * window in the queue, and a queue that would not drain stopped them
         * for good.
         */
        guard active else { return }
        /*
         * Only the window in front is copied.
         *
         * Every proxy holds one complete picture of its own window and nothing
         * else.  The window in front is the only one that can be read whole --
         * nothing is drawn over it -- so it is the only one copied, and every
         * copy of it is therefore complete.  When another window comes forward
         * this one simply stops being copied, and the last frame taken while
         * it was in front stays as its picture.
         *
         * Reading the windows behind as well is what caused the smearing and
         * the flashes of desktop: what the shared frame holds where another
         * window covers them is that other window.  Working out which parts
         * were safe to read, row by row, cost more every frame than the copy
         * itself and still left the covered parts wrong.
         */
        framesSinceFocus += 1
        guard let id = frontmostLive, let p = proxies[id] else { return }
        guard framesSinceFocus >= 3 else { return }   // it has repainted by now
        // For a few reports after a window moves or is resized the guest has
        // not painted it where it now is, and the frame still holds whatever
        // used to be there.
        guard fresh[id, default: 0] >= 3 else { return }
        if let snap = snapshot(id, p.guestRect) {
            p.setOwnSurface(snap)
            copyCount += 1
        }
    }

    /// Copies made of the window in front, and when counting started.
    private var copyCount = 0
    private var copyCountSince = Date()
    /// How often the window in front is actually being copied.
    func copyRate() -> String {
        let dt = Date().timeIntervalSince(copyCountSince)
        let r = dt > 0 ? Double(copyCount) / dt : 0
        let out = String(format: "PERATE %.1f copies/s over %.1fs (front=%d fresh=%d capturing=%d)",
                         r, dt, focusedGuestWindow, fresh[focusedGuestWindow, default: -99],
                         capturing ? 1 : 0)
        copyCount = 0; copyCountSince = Date()
        return out
    }

    /// The window to copy afresh: the one being worked in.
    ///
    /// Normally that is the guest's frontmost window, and the report runs front
    /// to back.  But the two can disagree for a moment -- a proxy takes focus
    /// here the instant it is clicked, while the guest is still being asked to
    /// raise the real window -- and in that moment the window the user is
    /// looking at is the one that must keep updating.  So the focused proxy
    /// wins, as soon as the guest agrees nothing is covering it.
    private var frontmostLive: Int? {
        /*
         * Nothing at all is copied until the guest has said which window is on
         * top.  There is no falling back on the window list's own order: it is
         * grouped by connection, so the window it names first is very often not
         * the one in front, and copying that one reads another window's pixels
         * into it.  A frame or two of nothing being copied is invisible; a
         * wrong copy stays on screen.
         */
        guard focusedGuestWindow != 0, proxies[focusedGuestWindow] != nil else { return nil }
        return focusedGuestWindow
    }

    func setSurface(_ s: IOSurfaceRef) {
        // Only remember it, to copy each window out of.  Handing the shared
        // screen to the windows themselves made every one of them show the
        // whole guest desktop for a frame -- they draw from their own copy,
        // whose contentsRect is the whole of that copy, so the shared screen
        // arriving underneath it was drawn entire, in every window at once.
        surface = s
    }

    /// A guest-window rectangle (points, top-left) mapped 1:1 to this Mac's
    /// screen (points, bottom-left), anchored at the top-left corner.  1:1 --
    /// not stretched to fill -- so a guest point and a screen point are the
    /// same distance apart, and clicks and drags land exactly.
    private func hostFrame(_ g: CGRect) -> CGRect {
        let s = scale
        return CGRect(x: screenFrame.minX + g.minX * s,
                      y: screenFrame.maxY - (offsetY + (g.minY + g.height) * s),
                      width: g.width * s, height: g.height * s)
    }

    /// The host rectangle a guest window maps to (for diagnostics).
    func hostFrameFor(_ g: CGRect) -> CGRect { hostFrame(g) }

    /// What each proxy window actually is on screen, for diagnosing a Harmony
    /// that draws nothing.
    func proxyReport() -> String {
        proxies.map { id, p in
            let f = p.frame
            return "\(id):frame=(\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height)))"
                 + ",vis=\(p.isVisible ? 1 : 0),a=\(String(format: "%.2f", p.alphaValue))"
                 + ",contents=\(p.hasContents ? 1 : 0),lvl=\(p.level.rawValue)"
        }.sorted().joined(separator: " ")
    }

    func update(_ windows: [(id: Int, rect: CGRect, visible: CGRect)]) {
        guard active else { return }
        // Leave out the menu bar: anything glued to the very top and shallow.
        // The guest reports it as several pieces -- the menu titles on the
        // left, the extras/clock on the right -- so a full-width test kept the
        // right-hand piece; matching any shallow top strip drops them all.
        // This Mac's own menu bar shows there instead.
        func isMenuBar(_ r: CGRect) -> Bool { r.minY <= 2 && r.height <= 30 }
        // The full-width piece is the bar itself; its height bottom-aligns the
        // two menu bars.
        if let mb = windows.first(where: { isMenuBar($0.rect) && $0.rect.width >= guestSize.width - 4 }) {
            guestMenuBar = mb.rect.height
        }
        // Leave out anything lying entirely off the guest's screen: the Dock's
        // icons sit below it while the Dock is hidden, and being first in the
        // list they were taken for the front-most window -- so no real window
        // was ever refreshed from the screen and every one of them sat frozen.
        func onScreen(_ r: CGRect) -> Bool {
            r.maxY > 0 && r.minY < guestSize.height && r.maxX > 0 && r.minX < guestSize.width
        }
        let shown = windows.filter { !isMenuBar($0.rect) && onScreen($0.rect) }
        // What covers what has to be known before anything is copied.  Working
        // from the previous report meant that for one frame after a window
        // appeared, everything under it still counted as uncovered -- so they
        // were copied with the new window's pixels across them, and the new
        // window was copied before the guest had painted it, which showed as
        // the two of them ghosting into each other.
        stack = windows
        /*
         * Anything that moved, appeared or went away makes what is known about
         * what covers what a lie -- and not only for itself.  Every window it
         * used to be over, or is now over, has to wait for the next report
         * before being copied again, or it is copied with the mover's pixels
         * still standing on it.  That is the smearing between windows: it is
         * the ones underneath that go wrong, and they are the ones that were
         * not put back on probation.
         */
        var disturbed: [CGRect] = []
        let nowShown = Set(shown.map { $0.id })
        for w in shown {
            if let was = lastRect[w.id] {
                if was != w.rect { disturbed.append(was.union(w.rect)) }
            } else {
                disturbed.append(w.rect)                  // newly appeared
            }
        }
        for (id, r) in lastRect where !nowShown.contains(id) { disturbed.append(r) }
        var live = Set<Int>()
        for w in shown {
            live.insert(w.id)
            let p = proxies[w.id] ?? {
                let n = HarmonyProxy(id: w.id, manager: self)
                // Nothing to show until this window has been copied: better
                // empty for a frame than the whole desktop.
                proxies[w.id] = n
                n.orderFront(nil)
                return n
            }()
            if p.isMiniaturized { p.deminiaturize(nil); p.minimizedPid = nil }
            vanished.removeValue(forKey: w.id)
            p.guestRect = w.rect
            // A window nothing covers is refreshed from the screen every
            // frame, so the one being worked in stays live; the rest keep the
            // copy taken while they were clear.  Nothing can be read from under
            // another window: the framebuffer holds whatever was drawn on top.
            // Newly appeared: the guest has not drawn it yet, so whatever is
            // in the framebuffer there still belongs to whatever was there
            // before.  Wait a few reports before believing it.
            // Just appeared, or just moved: the guest has not drawn it where it
            // now is, so the framebuffer there still holds whatever was behind
            // it -- which is the flash seen at the end of a drag.
            // Copies are now made on every frame from the guest, but what
            // covers what is only known when the guest reports, which is far
            // less often.  So anything that could make the last report a lie --
            // the window moving, resizing, or something coming over it -- puts
            // it back on probation until the next report confirms it.
            // Whether anything is over it is no longer worked out here: only
            // the window in front is copied, and it is the one nothing covers.
            // Doing it per window per report was O(n^2) for an answer nothing
            // needed any more.
            // From the guest's own answer, not the list's order: a pop-up
            // menu or a palette becomes the list's first window and would
            // otherwise re-arm probation on the window underneath it.
            let cov = w.id != focusedGuestWindow
            let was = lastRect[w.id]
            // Resizing is the slowest of these for the guest to catch up with:
            // it has to lay the window out again, and copying before it has
            // shows whatever the window used to be sitting on.  Give it longer
            // than a move or a change of stacking.
            if let was, was.size != w.rect.size, w.id != focusedGuestWindow {
                /*
                 * Resizing is the slowest of these for the guest to catch up
                 * with, so a window that is not in front waits.  The one in
                 * front does not wait at all: nothing is drawn over it, so any
                 * copy of it is a complete picture of it, and it is copied
                 * again on the very next frame.  Holding it back reset this on
                 * every report while the size kept changing, so it never
                 * reached the threshold and the window being resized was the
                 * one window that never redrew.
                 */
                fresh[w.id] = -6
            }
            else if was != w.rect || wasCovered[w.id] != cov { fresh[w.id] = 0 }
            else if disturbed.contains(where: { $0.intersects(w.rect) }) {
                fresh[w.id] = min(fresh[w.id, default: 0], 0)
            }
            lastRect[w.id] = w.rect
            wasCovered[w.id] = cov
            let age = fresh[w.id, default: 0]
            if age < 5 { fresh[w.id] = age + 1 }
            /*
             * Nothing is copied here.  A window keeps the complete picture it
             * already has -- taken while it was in front, or by the pass that
             * raises a window once to get one -- and only the window in front
             * is copied afresh, from the guest's own frames.
             */
            if let have = copies[w.id]?.front ?? copies[w.id]?.lastGood {
                // Same again: re-assigning the surface it already has draws
                // nothing but still costs a transaction per window per report.
                if !p.showing(have) { p.setOwnSurface(have) }
            } else {
                p.setContentsRect(normalized(w.rect))
            }
            if let want = p.pendingMove {
                // The guest has moved it (near enough), or it never will.
                if (abs(w.rect.minX - want.x) <= 2 && abs(w.rect.minY - want.y) <= 2)
                    || Date().timeIntervalSince(p.pendingSince) > 1.5 {
                    if Date().timeIntervalSince(p.pendingSince) > 1.5 {
                        harmonyDebug(String(format: "PEMOVE id=%d TIMED OUT, guest still at (%.0f,%.0f) want (%.0f,%.0f)",
                                            w.id, w.rect.minX, w.rect.minY, want.x, want.y))
                    }
                    p.pendingMove = nil
                    p.endDrag()
                }
            }
            if !p.dragging && p.pendingMove == nil {
                // Only when it has actually moved: this runs for every window
                // on every report, and each call costs a CATransaction.
                let want = hostFrame(w.rect)
                if p.frame != want { p.setFrame(want, display: true) }
            }
        }
        for (id, p) in proxies where !live.contains(id) {
            /*
             * Whatever becomes of the proxy, this window is off the guest's
             * screen, so everything remembered about where it was must go now.
             *
             * It used to be cleaned up only on the path that throws the proxy
             * away -- which a minimised window never takes.  Its last rectangle
             * then stayed in `lastRect` for the rest of the session, and the
             * "something moved here" list below re-added it on every report,
             * so every window overlapping where it used to be was held on
             * probation for ever and never copied again.
             */
            fresh.removeValue(forKey: id); lastRect.removeValue(forKey: id)
            wasCovered.removeValue(forKey: id); captureMisses.removeValue(forKey: id)
            /*
             * A window that has gone from the guest's screen has either been
             * closed or put in the guest's Dock -- and the guest's Dock is
             * hidden, so a minimised window would be gone for good.  Minimise
             * its proxy into this Mac's Dock instead: it keeps the picture it
             * had, and clicking it there brings the real window back.
             *
             * Which of the two it was is only known a report later: the guest
             * sends its window list first and what is in its Dock on the back
             * of it.  So the proxy is given that one report -- no more, or a
             * window that was simply closed hangs about on screen after it.
             */
            if vanished[id] == nil {
                vanished[id] = Date()
                // Only a window that goes into the Dock *after* this one left
                // the screen can be this one.  Matching against whatever was
                // already minimised gave the first window the user closed
                // somebody else's Dock entry, and left it there for good.
                minimizedBefore = Set(minimizedEntries.map { "\($0.pid)/\($0.index)" })
            }
            if !p.isMiniaturized, let e = unboundMinimized() {
                p.minimizedPid = e.pid
                p.minimizedIndex = e.index
                p.title = e.title.isEmpty ? "Virtual Mac window" : e.title
                /*
                 * No genie.  The guest has already played its own minimise
                 * into a Dock that is hidden, so a second animation here is
                 * both wrong and late; the window should simply be in the
                 * Dock.  The Dock's effect is a setting of this Mac's that is
                 * not ours to change, so the window is told not to animate
                 * instead.
                 */
                p.animationBehavior = .none
                // miniaturize() does nothing to these windows; performMiniaturize
                // is the one that puts them in the Dock.
                p.performMiniaturize(nil)
                continue
            }
            if p.isMiniaturized { continue }         // already waiting in the Dock
            // One report's grace for the guest's Dock report to arrive, no more.
            if let since = vanished[id], Date().timeIntervalSince(since) < 0.17 { continue }
            vanished.removeValue(forKey: id)
            p.orderOut(nil); proxies.removeValue(forKey: id)
            copies.removeValue(forKey: id); cleanSnapshots.remove(id)
        }
        // Any window that is covered and has no clean copy of itself gets one:
        // it is brought to the front for a moment so the guest repaints it,
        // copied, and the window that was in front is put back.  Doing it this
        // way rather than once on the way in survives the Finder restarting
        // (Harmony asks it to, which gives all its windows new numbers) and
        // windows opened later.
        /*
         * The window in front is never queued: it is copied from every frame
         * anyway, so it needs no pass -- and a pass stops all copying for a
         * second or more per window while it raises them in turn.  Resizing a
         * window drops its picture, and the window being resized is nearly
         * always the one being worked in, so queueing it froze the very window
         * the user was dragging the corner of.
         */
        for w in shown where !cleanSnapshots.contains(w.id) && proxies[w.id] != nil
                             && !captureQueue.contains(w.id) && w.id != focusedGuestWindow
                             && !gaveUp.contains(w.id) {
            // Put the focused window back afterwards, not whatever the list
            // happens to name first -- its order is grouped by connection.
            if captureQueue.isEmpty {
                captureRestore = (focusedGuestWindow != 0 && proxies[focusedGuestWindow] != nil)
                    ? focusedGuestWindow : stack.first(where: { proxies[$0.id] != nil })?.id
            }
            captureQueue.append(w.id)
            capturing = true
            harmonyDebug("PECAP queue \(w.id)")
        }
        if ProcessInfo.processInfo.environment["POWEREMU_HARMONY_DEBUG"] != nil {
            capDebugTick += 1
            if capDebugTick % 30 == 0 {
                let d = shown.map { w in
                    "\(w.id):cov=\(isCovered(w.id, w.rect) ? 1 : 0),clean=\(cleanSnapshots.contains(w.id) ? 1 : 0)"
                }.joined(separator: " ")
                harmonyDebug("PECAPDBG stack=\(stack.count) q=\(captureQueue) capturing=\(capturing) \(d)")
            }
        }
        stepInitialCapture()
        updateMenuBar()
        /*
         * Only windows that have just appeared are brought forward here.
         *
         * The guest layers by application: clicking any window of an
         * application brings all of that application's windows forward, which
         * is how Mac OS has always worked and is not something the guest can be
         * talked out of.  Mirroring it here meant that clicking one guest
         * window threw every other window of that application over this Mac's
         * own windows, which is not what a window on this desktop should do.
         *
         * Each proxy now holds its own complete picture, so the two orders no
         * longer have to agree for the pictures to be right -- which is what
         * makes leaving this Mac's order alone possible at all.
         */
        let wanted = shown.map { $0.id }
        for id in wanted.reversed() where !order.contains(id) {
            guard let p = proxies[id], !p.isMiniaturized else { continue }
            p.orderFront(nil)
        }
        order = wanted
    }

    /// Keep the guest's menu bar strip on screen, above the proxies and above
    /// this Mac's own menu bar.
    private func updateMenuBar() {
        // The guest's own menu bar is never shown: this Mac's menu bar is meant
        // to carry the focused guest application's menus instead (which needs
        // the Accessibility API to read them).  Until then, show neither.
        menuBar?.orderOut(nil); menuBar = nil
        if true { return }
        guard active, guestSize.width > 0, guestMenuBar > 0 else { return }
        let strip = CGRect(x: 0, y: 0, width: guestSize.width, height: guestMenuBar)
        let m = menuBar ?? {
            let n = HarmonyProxy(id: -1, manager: self)
            n.isMenuBar = true
            n.level = .statusBar            // above the proxies and this Mac's menu bar
            n.hasShadow = false
            (n.contentView as? NSView)?.layer?.cornerRadius = 0
            if let s = surface { n.setSurface(s as! IOSurfaceRef) }
            menuBar = n
            n.orderFront(nil)
            return n
        }()
        m.guestRect = strip
        m.setContentsRect(normalized(strip))
        m.setFrame(hostFrame(strip), display: true)
        m.order(.above, relativeTo: 0)
    }

    /// Copy a window's pixels out of the shared frame into its own surface.
    ///
    /// Only ever called for a window nothing is covering -- the one in front,
    /// or one the capture pass has raised -- so the copy is always a complete
    /// picture of that window and of nothing else.
    private func snapshot(_ id: Int, _ g: CGRect) -> IOSurfaceRef? {
        let w = Int(g.width.rounded()), h = Int(g.height.rounded())
        guard w > 0, h > 0 else { return copies[id]?.front }
        let c = copies[id] ?? { let n = WindowCopy(); copies[id] = n; return n }()
        // Rebuild the pair whenever the window changes size.
        if c.surfaces.count != 2 || IOSurfaceGetWidth(c.surfaces[0]) != w
            || IOSurfaceGetHeight(c.surfaces[0]) != h {
            cleanSnapshots.remove(id)
            let bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4)
            let props: [CFString: Any] = [kIOSurfaceWidth: w, kIOSurfaceHeight: h,
                                          kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: bpr,
                                          kIOSurfacePixelFormat: 0x42475241 /* 'BGRA' */]
            c.surfaces = (0..<2).compactMap { _ in IOSurfaceCreate(props as CFDictionary) }
            c.back = 0
            guard c.surfaces.count == 2 else { return c.lastGood }
        }
        guard let src = surface as! IOSurfaceRef? else { return c.front }
        let dst = c.surfaces[c.back]
        let sw = IOSurfaceGetWidth(src), sh = IOSurfaceGetHeight(src)
        let gx = Int(g.minX.rounded()), gy = Int(g.minY.rounded())
        /*
         * A window can hang off the edges of the guest's screen.  Where it
         * does there is nothing to read, so the copy starts further into the
         * window rather than further into the screen -- clamping the source
         * alone slid the window's contents sideways by however far off the
         * edge it was.  What is not written is cleared, or it keeps whatever
         * this buffer held two copies ago and shows as a stale stripe.
         */
        let dx = max(0, -gx), dy = max(0, -gy)
        let ox = max(0, gx), oy = max(0, gy)
        let cols = max(0, min(w - dx, sw - ox))
        let rows = max(0, min(h - dy, sh - oy))

        IOSurfaceLock(src, .readOnly, nil)
        IOSurfaceLock(dst, [], nil)
        let sb = IOSurfaceGetBaseAddress(src), db = IOSurfaceGetBaseAddress(dst)
        let sbpr = IOSurfaceGetBytesPerRow(src), dbpr = IOSurfaceGetBytesPerRow(dst)
        if cols < w || rows < h { memset(db, 0, dbpr * h) }      // the part off-screen
        if cols > 0 {
            for row in 0..<rows {
                memcpy(db.advanced(by: (dy + row) * dbpr + dx * 4),
                       sb.advanced(by: (oy + row) * sbpr + ox * 4), cols * 4)
            }
        }
        IOSurfaceUnlock(dst, [], nil)
        IOSurfaceUnlock(src, .readOnly, nil)

        c.back = 1 - c.back
        let shown = c.surfaces[1 - c.back]
        c.lastGood = shown
        cleanSnapshots.insert(id)
        return shown
    }

    /// Start the pass that gives every window a clean copy of itself.
    func beginInitialCapture() {
        guard active, !stack.isEmpty else { return }
        captureQueue = stack.filter { proxies[$0.id] != nil }.map { $0.id }.reversed()
        captureRestore = stack.first(where: { proxies[$0.id] != nil })?.id
        captureTicks = 0
        capturing = !captureQueue.isEmpty
        harmonyDebug("PECAP begin \(captureQueue)")
    }

    /// One window at a time: raise it, let the guest repaint it, copy it.
    private func stepInitialCapture() {
        guard capturing else { return }
        // However the queue emptied -- finished, or its windows closed under it
        // -- the flag has to come off: while it is set every window counts as
        // covered, so none of them refresh and the whole desktop sits frozen.
        guard let id = captureQueue.first else { finishCapture(); return }
        guard proxies[id] != nil else { captureQueue.removeFirst(); captureTicks = 0; return }
        captureTicks += 1
        if captureTicks == 1 {
            captureBegan = Date()
            /*
             * A hard raise: the application comes up with the window.  A click
             * deliberately does not do that -- only the window clicked should
             * come forward -- but this pass has to be certain the window really
             * is on top, because it is about to store whatever is on the screen
             * there as that window's picture for good.
             */
            askGuestToRaise(id, hard: true)
            return
        }
        /*
         * It has to stay on top for the whole wait, not merely be on top at the
         * end of it.  Entering Harmony moves a great deal about at once -- the
         * Finder is restarted, the Dock is hidden, the screen changes size --
         * and a window can be reported in front for an instant while the screen
         * still holds what was over it.  Copying then stored another window's
         * picture as this one's and marked it good for ever.
         */
        if focusedGuestWindow != id {
            /*
             * Wait for it to come forward, but not indefinitely.  Resetting the
             * tick count alone meant the raise at tick 1 never fired again and
             * the count never reached the give-up path below, so a window the
             * guest would not raise -- one that closed under the pass, or a
             * palette owned by a background application -- left the pass
             * running for ever.
             */
            if Date().timeIntervalSince(captureBegan) > 4 {
                captureTicks = 18                   // fall through to the miss
            } else {
                captureTicks = 1
                return
            }
        }
        // The guest is slow: give it real time to paint before copying, or the
        // copy is of whatever was there before -- the desktop, usually.
        guard captureTicks >= 18 else { return }   // ~1.5s at the report rate
        /*
         * Only copy it if the guest says it really did come to the front.
         *
         * This pass raises a window so it can be read whole.  If the raise did
         * not take -- the application would not come forward, the window was in
         * the Dock, it closed under us -- then what is on screen where that
         * window is, is some other window, and copying it stored that other
         * window's pixels as this one's complete picture and marked it good
         * for ever.  That is a window "leaving its surface" on another: the
         * damage was done once, here, and every frame afterwards faithfully
         * showed it.
         */
        if focusedGuestWindow == id, let p = proxies[id] {
            _ = snapshot(id, p.guestRect)
            harmonyDebug("PECAP took \(id)")
        } else {
            captureMisses[id, default: 0] += 1
            harmonyDebug("PECAP skipped \(id): focus is \(focusedGuestWindow)"
                         + " (miss \(captureMisses[id, default: 0]))")
            // Give up after a few tries rather than raising windows for ever;
            // it will be copied properly the first time it is worked in.
            if captureMisses[id, default: 0] >= 3 { gaveUp.insert(id) }
            if captureMisses[id, default: 0] < 3 {
                captureQueue.removeFirst()
                captureQueue.append(id)
                captureTicks = 0
                if captureQueue.count == 1 { finishCapture() }
                return
            }
        }
        captureQueue.removeFirst()
        captureTicks = 0
        if captureQueue.isEmpty { finishCapture() }
    }

    private func finishCapture() {
        capturing = false
        captureQueue = []
        if let r = captureRestore { askGuestToRaise(r, hard: true); captureRestore = nil }
        harmonyDebug("PECAP done")
        /*
         * Once more when the dust has settled.  The first pass runs while
         * Harmony is still rearranging the guest, so some of its copies can be
         * of a screen that was still changing; by now nothing is moving and
         * every window can be caught properly.
         */
        if !didSettleCapture {
            didSettleCapture = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.active else { return }
                self.cleanSnapshots.removeAll()
                self.captureMisses.removeAll()
                self.gaveUp.removeAll()
                harmonyDebug("PECAP settle pass")
            }
        }
    }

    /// Why a window is or is not being copied afresh from every frame, and
    /// how much of it is readable.
    func liveness(_ id: Int) -> String {
        let over = occluders(id)
        let area = stack.first(where: { $0.id == id }).map { $0.rect.width * $0.rect.height } ?? 0
        let hidden = over.reduce(0) { $0 + $1.width * $1.height }
        let pct = area > 0 ? Int(min(100, hidden / area * 100)) : -1
        let settled = fresh[id, default: 0] >= 3
        return "over=\(over.count) hidden~\(pct)% focus=\(focusedGuestWindow == id ? 1 : 0) "
            + "fresh=\(fresh[id, default: -99]) "
            + "capturing=\(capturing ? 1 : 0) clean=\(cleanSnapshots.contains(id) ? 1 : 0) "
            + "live=\((settled && !capturing) ? 1 : 0)"
    }

    /// Write a window's own copy of itself to a PNG, to check by eye that the
    /// copies are right (POWEREMU_HARMONY_DEBUG only).
    func writeSnapshot(_ id: Int, to path: String) -> String {
        guard let snap = copies[id]?.front else { return "no snapshot for \(id)" }
        let w = IOSurfaceGetWidth(snap), h = IOSurfaceGetHeight(snap)
        IOSurfaceLock(snap, .readOnly, nil)
        defer { IOSurfaceUnlock(snap, .readOnly, nil) }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: IOSurfaceGetBaseAddress(snap), width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: IOSurfaceGetBytesPerRow(snap),
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue),
              let img = ctx.makeImage() else { return "could not read \(id)" }
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         "public.png" as CFString, 1, nil)
        else { return "could not write \(path)" }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return "wrote \(w)x\(h) to \(path)"
    }

    /// Check by hand that a proxy really can go in the Dock.
    func testMiniaturize(_ id: Int) -> String {
        guard let p = proxies[id] else { return "no proxy \(id)" }
        let before = "vis=\(p.isVisible) lvl=\(p.level.rawValue) style=\(p.styleMask.rawValue) "
                   + "canMin=\(p.styleMask.contains(.miniaturizable)) active=\(NSApp.isActive)"
        p.miniaturize(nil)
        let afterA = p.isMiniaturized
        p.performMiniaturize(nil)
        let afterB = p.isMiniaturized
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            harmonyDebug("PETESTMIN later id=\(id) miniaturized=\(p.isMiniaturized)")
        }
        return "\(before) afterMiniaturize=\(afterA) afterPerform=\(afterB)"
    }

    /// A minimised guest window that no proxy is standing in for yet.
    private func unboundMinimized() -> (pid: Int, index: Int, title: String)? {
        let taken = Set(proxies.values.compactMap { p -> String? in
            guard let pid = p.minimizedPid else { return nil }
            return "\(pid)/\(p.minimizedIndex)"
        })
        return minimizedEntries.first {
            let key = "\($0.pid)/\($0.index)"
            // Not already claimed, and not one that was already in the guest's
            // Dock before this window left the screen.
            return !taken.contains(key) && !minimizedBefore.contains(key)
        }
    }
    /// What was already in the guest's Dock when a window last vanished.
    private var minimizedBefore = Set<String>()

    /*
     * The parts of the screen lying on top of this window, in guest
     * coordinates.
     *
     * A window is rarely all covered or all clear: nearly always some of it
     * shows and some of it is behind something else.  Treating any overlap at
     * all as "covered" froze the whole window -- the wide margins of it that
     * were plainly visible stopped updating with the rest, which is what
     * looked like windows holding stale pictures of each other.
     *
     * The report is already front to back, so everything ahead of this window
     * in it is on top of it.
     */
    private func occluders(_ id: Int) -> [CGRect] {
        var out: [CGRect] = []
        guard let me = stack.first(where: { $0.id == id }) else { return out }
        for w in stack {
            if w.id == id { break }                   // reached it: the rest is behind
            // Only windows that are actually shown here: the menu bar, the
            // Dock and anything off screen have no proxy and cover nothing.
            // The list runs front to back and proxies are made in that order,
            // so everything ahead of this window already has one.
            guard proxies[w.id] != nil else { continue }
            let hit = w.rect.intersection(me.rect)
            if !hit.isNull && hit.width >= 1 && hit.height >= 1 { out.append(hit) }
        }
        return out
    }

    /// Whether anything at all is on top of it (for probation and reporting).
    private func isCovered(_ id: Int, _ rect: CGRect) -> Bool {
        !occluders(id).isEmpty
    }

    private func normalized(_ g: CGRect) -> CGRect {
        let gw = guestSize.width, gh = guestSize.height
        guard gw > 0, gh > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: g.minX / gw, y: (gh - (g.minY + g.height)) / gh,
                      width: g.width / gw, height: g.height / gh)
    }

    /// The top band is this Mac's menu bar (which doubles as the guest's).  A
    /// click there is never the guest's -- the guest's own menu bar sits behind
    /// it, and injecting there popped the guest's menus when this Mac's menu bar
    /// was clicked.
    func cursorInHostMenuBar() -> Bool {
        guard screenFrame.height > 0 else { return false }
        return (screenFrame.maxY - NSEvent.mouseLocation.y) < hostMenuBar
    }

    /// Taken out of this Mac's Dock: put the guest's window back too.
    func windowDidDeminiaturize(_ n: Notification) {
        guard let p = n.object as? HarmonyProxy, let pid = p.minimizedPid else { return }
        harmonyDebug("PEUNMIN id=\(p.id) pid=\(pid)/\(p.minimizedIndex)")
        unminimize?(pid, p.minimizedIndex)
        p.minimizedPid = nil
    }

    /// The scale the windows are drawn at, so the guest's pointer can be drawn
    /// to match them.
    var guestScale: CGFloat { scale }
    var guestOffsetY: CGFloat { offsetY }
    /// The guest point this Mac's pointer maps to -- exactly what a click
    /// sends.  The overlay shows it beside where the guest says its pointer
    /// actually is, so the two can be compared while the mouse moves.
    func guestPointAtCursor() -> CGPoint {
        let s = scale
        let h = NSEvent.mouseLocation
        return CGPoint(x: (h.x - screenFrame.minX) / s,
                       y: ((screenFrame.maxY - h.y) - offsetY) / s)
    }
    /// A guest point (top-left origin, guest px) as a point in the Harmony view
    /// (bottom-left origin) -- the exact mapping the windows use, so the guest's
    /// drawn pointer lands on the window pixel under it rather than drifting.
    func viewPoint(forGuest g: CGPoint) -> CGPoint {
        let s = scale
        return CGPoint(x: g.x * s, y: screenFrame.height - (offsetY + g.y * s))
    }

    // Input from a proxy.  The guest's pointer is put wherever this Mac's is,
    // in guest points, mapped globally -- so clicks and drags are right even
    // while a proxy is moving.
    func sendPointAtCursor() {
        guard screenFrame.width > 0, !cursorInHostMenuBar() else { return }
        let s = scale
        let h = NSEvent.mouseLocation
        sendPoint?(Int((h.x - screenFrame.minX) / s),
                   Int(((screenFrame.maxY - h.y) - offsetY) / s))
    }
    func proxyButton(_ down: Bool) { sendButton?(1, down) }

    /// A point on this guest window that nothing in front of it covers, in
    /// guest coordinates -- somewhere a synthetic click really will land on it.
    /// Prefers the title bar (so the same point can drag the window), then
    /// works down the window.  nil when it is completely buried.
    func uncoveredPoint(of id: Int, titleBarOnly: Bool = true) -> CGPoint? {
        guard let idx = stack.firstIndex(where: { $0.id == id }) else { return nil }
        let r = stack[idx].rect
        let above = stack[0..<idx].map { $0.rect }
        func free(_ p: CGPoint) -> Bool { !above.contains { $0.insetBy(dx: -1, dy: -1).contains(p) } }
        // Along the title bar first: middle outwards, avoiding the close/zoom
        // buttons on the left and the toolbar button on the right.
        let ty = r.minY + 11
        var xs: [CGFloat] = [r.midX]
        var step: CGFloat = 24
        while step < r.width / 2 - 70 { xs.append(r.midX - step); xs.append(r.midX + step); step += 24 }
        for x in xs where x > r.minX + 70 && x < r.maxX - 40 {
            let p = CGPoint(x: x, y: ty)
            if free(p) { return p }
        }
        if titleBarOnly { return nil }
        for fy in stride(from: 0.2, through: 0.9, by: 0.1) {
            for fx in stride(from: 0.15, through: 0.85, by: 0.1) {
                let p = CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * CGFloat(fy))
                if free(p) { return p }
            }
        }
        return nil
    }

    /// POWEREMU_HARMONY_DEBUG=1: one line per click, to check by hand that the
    /// picture and the arithmetic agree.  `frame` is where the proxy actually
    /// ended up; if it differs from `want`, something moved it.
    func logClick(_ p: HarmonyProxy) {
        guard ProcessInfo.processInfo.environment["POWEREMU_HARMONY_DEBUG"] != nil else { return }
        let h = NSEvent.mouseLocation
        let fromTop = screenFrame.maxY - h.y
        harmonyDebug(String(format: "PEHARMONY host=(%.0f,%.0f) fromTop=%.0f screen=%.0fx%.0f surface=%.0fx%.0f scale=%.4f offsetY=%.0f hostMB=%.0f guestMB=%.0f guestPt=(%.0f,%.0f) guestRect=%@ frame=%@ want=%@",
              h.x, h.y, fromTop, screenFrame.width, screenFrame.height,
              guestSize.width, guestSize.height, scale, offsetY, hostMenuBar, guestMenuBar,
              (h.x - screenFrame.minX) / scale, (fromTop - offsetY) / scale,
              String(describing: p.guestRect), String(describing: p.frame),
              String(describing: hostFrame(p.guestRect))))
    }
    /*
     * Ask the guest to raise a window, and stop copying anything until it says
     * which window is on top now.
     *
     * The guest reports the front window twelve times a second; a raise takes
     * effect before that.  In between, the window that *was* in front is still
     * the one being copied -- while the new one is already drawn over it -- so
     * it ends up holding a picture of the window that rose in front of it.
     * That is a window "leaving its surface" on another, and it happened on
     * every raise: a click, and each step of the capture pass.
     */
    private func askGuestToRaise(_ id: Int, hard: Bool) {
        focusedGuestWindow = 0                  // nothing is copied until confirmed
        if hard { raiseWindowHard?(id) } else { raiseWindow?(id) }
    }

    func proxyRaise(_ id: Int) {
        /*
         * A click inside the window that is already in front is not a raise.
         *
         * Asking the guest to raise it anyway stopped the copying until the
         * guest answered, and then put the window back on probation for
         * another few reports -- so every click inside the active window cost
         * the best part of a second before what it did showed up.  Changing a
         * Finder window's view or folder is exactly that: a click in the window
         * already in front.
         */
        if id == focusedGuestWindow {
            proxies[id]?.orderFront(nil)
            return
        }
        // The guest raises it through the Accessibility API.  It used to be
        // done by faking a click on a patch of the window nothing covered,
        // which landed next to the reader's own click and read as a
        // double-click -- minimising the window instead of raising it.
        askGuestToRaise(id, hard: false)
        // A click on a proxy raises it on this Mac by itself, but a raise asked
        // for any other way (the Dock menu, a test) has to say so, now that
        // this Mac's order is no longer rebuilt from the guest's.
        proxies[id]?.orderFront(nil)
    }


    /// A title-bar drag has ended: turn the proxy's final place on this Mac's
    /// screen back into guest points (top-left) and move the guest window there
    /// once.  During the drag only the proxy moves -- the guest window stays put
    /// and fully drawn -- so the desktop never shows through behind it.
    func moveProxyToGuest(_ id: Int, origin: CGPoint) {
        guard let p = proxies[id] else { return }
        let s = scale
        let gx = (origin.x - screenFrame.minX) / s
        let fromTop = screenFrame.maxY - (origin.y + p.frame.height)   // the window's top edge
        let gy = (fromTop - offsetY) / s
        requestGuestMove(id, to: CGPoint(x: gx, y: gy))
    }

    /// Ask the guest to put a window's top-left at a guest point.
    func requestGuestMove(_ id: Int, to target: CGPoint) {
        guard let p = proxies[id] else { return }
        // The guest sets the position outright, so it does not matter whether
        // anything covers the window: it needs no part of it to take hold of.
        let from = p.guestRect.origin
        p.pendingMove = CGPoint(x: target.x.rounded(), y: target.y.rounded())
        p.pendingSince = Date()
        /*
         * Stop copying it until the guest confirms where it is.  From the
         * moment the guest moves the window, the part of the frame this proxy
         * was being read from holds whatever is behind it now -- the desktop,
         * usually -- and the report saying so is up to a twelfth of a second
         * behind.  Reading it in between is the flash of desktop at the end of
         * a drag.
         */
        fresh[id] = -6
        harmonyDebug(String(format: "PEMOVE id=%d %.0f,%.0f -> %.0f,%.0f",
                            id, from.x, from.y, target.x, target.y))
        moveWindowDrag?(id, Int(from.x.rounded()), Int(from.y.rounded()),
                        Int(target.x.rounded()), Int(target.y.rounded()))
    }

}

/// One guest window as a borderless macOS window.
@MainActor
final class HarmonyProxy: NSWindow {
    let id: Int
    weak var manager: HarmonyWindowManager?
    var guestRect = CGRect.zero
    /// Where this window was dropped, until the guest reports it there.
    var pendingMove: CGPoint?
    var pendingSince = Date.distantPast
    private(set) var dragging = false
    /// The guest's menu bar strip, which owns clicks in the menu-bar band.
    var isMenuBar = false
    /// Set while this proxy is standing in for a minimised guest window.
    var minimizedPid: Int?
    var minimizedIndex = 0
    private let tex = CALayer()

    init(id: Int, manager: HarmonyWindowManager) {
        self.id = id
        self.manager = manager
        /*
         * Titled rather than borderless, with the title bar made invisible and
         * the content filling the whole window.  It looks exactly the same, but
         * a borderless window cannot be put in the Dock -- miniaturize() simply
         * does nothing -- and a guest window that has been minimised needs to
         * go somewhere the reader can get it back from, now that the guest's
         * own Dock is hidden.
         */
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.titled, .miniaturizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovable = false          // it is moved from here, never by the frame
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(b)?.isHidden = true
        }
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        acceptsMouseMovedEvents = true     // so the guest's pointer follows over a window too
        isMovableByWindowBackground = false
        level = .normal
        let v = HarmonyProxyView(proxy: self)
        v.wantsLayer = true
        v.layer = CALayer()
        v.layer?.cornerRadius = 6           // Aqua windows are rounded; the shadow follows this shape
        v.layer?.masksToBounds = true
        v.layer?.addSublayer(tex)
        tex.contentsGravity = .resize
        tex.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "contentsRect": NSNull()]
        contentView = v
        delegate = manager
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// A proxy must sit exactly where the guest's window is, to the pixel.
    /// AppKit otherwise nudges windows back into the visible area -- down from
    /// under the menu bar, up from past the bottom -- which left the picture
    /// somewhere other than where the click arithmetic thought it was, so a
    /// click near the top landed above the pointer and one near the bottom
    /// below it, while the middle of the screen was exact.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func setSurface(_ s: IOSurfaceRef) { tex.contents = s }
    /// Draw from this window's own copy of its pixels: the whole surface, so
    /// no contentsRect is needed.
    var hasContents: Bool { tex.contents != nil }
    /// Whether this is already the surface being shown, and at full size.
    func showing(_ s: IOSurfaceRef) -> Bool {
        (tex.contents as AnyObject?) === (s as AnyObject) && tex.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func setOwnSurface(_ s: IOSurfaceRef) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tex.contents = s
        tex.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        tex.frame = contentView?.bounds ?? .zero
        CATransaction.commit()
    }
    func setContentsRect(_ r: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tex.contentsRect = r
        tex.frame = contentView?.bounds ?? .zero
        CATransaction.commit()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tex.frame = contentView?.bounds ?? .zero
        CATransaction.commit()
    }

    func beginDrag() { dragging = true }
    func endDrag() { dragging = false }
}

/// The proxy's content view: a click focuses the guest window and passes the
/// button through; a drag on the title-bar band moves the window (and tells the
/// guest to move its own); other clicks go to the guest.
@MainActor
final class HarmonyProxyView: NSView {
    private weak var proxy: HarmonyProxy?
    private var dragOrigin: NSPoint?          // proxy origin at mouse-down (title-bar drag)
    private var dragMouse: NSPoint?           // screen mouse at mouse-down
    private var dragMoved = false             // told apart on release: click or drag

    init(proxy: HarmonyProxy) { self.proxy = proxy; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The wheel belongs to whatever the pointer is over, like any other
    /// pointer event: put the guest's pointer there first, then turn the wheel.
    private var scrollCarry: CGFloat = 0
    override func scrollWheel(with e: NSEvent) {
        guard let m = proxy?.manager else { return }
        m.sendPointAtCursor()
        // Trackpads give pixels; the guest counts wheel clicks.
        scrollCarry += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 12 : e.scrollingDeltaY
        let lines = Int32(scrollCarry.rounded(.towardZero))
        guard lines != 0 else { return }
        scrollCarry -= CGFloat(lines)
        m.sendScroll?(lines)
    }

    override func keyDown(with e: NSEvent) { proxy?.manager?.forwardKey?(e) }
    override func keyUp(with e: NSEvent) { proxy?.manager?.forwardKey?(e) }
    override func flagsChanged(with e: NSEvent) { proxy?.manager?.forwardKey?(e) }

    override func mouseDown(with e: NSEvent) {
        guard let proxy, let m = proxy.manager else { return }
        if !proxy.isMenuBar && m.cursorInHostMenuBar() { return }   // that band is this Mac's
        m.logClick(proxy)
        if proxy.isMenuBar {                          // the guest's menu bar: pass the click on
            m.sendPointAtCursor(); m.proxyButton(true)
            return
        }
        m.proxyRaise(proxy.id)                        // bring the real guest window to the front
        let p = convert(e.locationInWindow, from: nil)
        if p.y >= bounds.height - 22 {
            /*
             * The title bar carries the close, minimise and zoom buttons as
             * well as being the handle to drag by, and which one a press means
             * is not known until it is let go of: a press that never moves is a
             * click for the guest, a press that moves is a drag of the window.
             * Sending the press straight through would have the guest drag its
             * own window as well as the proxy moving.
             */
            dragOrigin = proxy.frame.origin
            dragMouse = NSEvent.mouseLocation
            dragMoved = false
            m.suspendPointerTracking = true
        } else {                                      // content: the click is the guest's
            m.sendPointAtCursor(); m.proxyButton(true)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let proxy, let m = proxy.manager else { return }
        if let o = dragOrigin, let dm = dragMouse {
            let now = NSEvent.mouseLocation
            if !dragMoved, abs(now.x - dm.x) < 3, abs(now.y - dm.y) < 3 { return }  // still a click
            if !dragMoved { dragMoved = true; proxy.beginDrag() }
            proxy.setFrameOrigin(NSPoint(x: o.x + (now.x - dm.x), y: o.y + (now.y - dm.y)))
        } else {
            m.sendPointAtCursor()
        }
    }

    override func mouseUp(with e: NSEvent) {
        guard let proxy, let m = proxy.manager else { return }
        if dragOrigin != nil {
            if dragMoved {                            // a drag: put the guest's window where it landed
                m.moveProxyToGuest(proxy.id, origin: proxy.frame.origin)
            } else {                                  // a click: the guest's to handle, buttons and all
                m.suspendPointerTracking = false
                m.sendPointAtCursor()
                m.proxyButton(true)
                m.proxyButton(false)
            }
            dragOrigin = nil; dragMouse = nil; dragMoved = false
            m.suspendPointerTracking = false
        } else {
            m.sendPointAtCursor(); m.proxyButton(false)
        }
    }

}
