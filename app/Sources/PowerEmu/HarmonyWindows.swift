import AppKit
import IOSurface
import ImageIO
import UniformTypeIdentifiers

/// POWEREMU_HARMONY_DEBUG=1: the pointer mapping, written to a plain file so it
/// can be read from outside the app (the system log does not carry it).
let harmonyDebugFile: FileHandle? = {
    guard ProcessInfo.processInfo.environment["POWEREMU_HARMONY_DEBUG"] != nil else { return nil }
    let path = ProcessInfo.processInfo.environment["POWEREMU_HARMONY_DEBUG_PATH"]
        ?? "/tmp/poweremu-harmony.log"
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
/// message); the manager keeps one `HarmonyProxy` window per id with a complete
/// backing-store image. Focus is acknowledged before content input is sent.
/// Host dragging retains that image and commits the guest position on release.
@MainActor
final class HarmonyWindowManager: NSObject, NSWindowDelegate {
    // Experimental complete-window source. No screen crops or focus cycling.
    let completeWindowCapture = ProcessInfo.processInfo.environment["POWEREMU_HARMONY_MASKED"] != "1"
    private(set) var guestCursor = NSCursor.arrow
    func setGuestCursor(_ image: CGImage?, hotSpot: CGPoint) {
        if let image {
            guestCursor = NSCursor(image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)), hotSpot: hotSpot)
        } else { guestCursor = .arrow }
        for proxy in proxies.values {
            if let view = proxy.contentView { proxy.invalidateCursorRects(for: view) }
        }
    }
    var releaseInput: (() -> Void)?
    var onGuestWindowFocus: ((Bool) -> Void)?
    private var keyWindowObserver: Any?
    var requestWindowFrame: ((Int, Int, Int) -> Void)?
    private var windowFrameTimer: Timer?
    private let frameDecodeQueue = DispatchQueue(label: "PowerEmu.windowDecode", qos: .userInitiated)
    private var decodingFrame = false
    private var requestedFrame: Int?
    private var requestSequence = 0
    private var requestedProxy: HarmonyProxy?
    private var captureScheduler = HarmonyCaptureScheduler()
    private var requestedBaseSequence = 0
    private var captureBeganAt = Date.distantPast
    private var capturedFrameCount = 0
    private var capturedFrameMilliseconds: Double = 0
    private var decodedFrameMilliseconds: Double = 0
    private var recentFrameTimings: [(unchanged: Bool, milliseconds: Double, bytes: Int)] = []

    private func requestNextFrame() {
        guard active, completeWindowCapture, !decodingFrame else { return }
        if requestedFrame != nil {
            guard Date().timeIntervalSince(captureBeganAt) > 3 else { return }
            harmonyDebug("PEWINDOWFRAME timeout id=\(requestedFrame ?? 0)")
            if let id = requestedFrame { captureScheduler.failed(id, now: ProcessInfo.processInfo.systemUptime) }
            requestedFrame = nil; requestedProxy = nil
        }
        // A guest app left focused while the user works in a host app should
        // not keep consuming the foreground capture budget.
        let foreground = NSApp.isActive
            ? (pendingFocus?.id ?? (NSApp.keyWindow as? HarmonyProxy)?.id) : nil
        let candidates = order.compactMap { id -> HarmonyCaptureScheduler.Candidate? in
            guard let p = proxies[id], !p.isMiniaturized else { return nil }
            let needsImage = !p.hasContents || p.capturedImage?.width != Int(p.guestRect.width)
                || p.capturedImage?.height != Int(p.guestRect.height)
            return .init(id: id, needsImage: needsImage)
        }
        guard let id = captureScheduler.next(candidates, foreground: foreground,
                                             now: ProcessInfo.processInfo.systemUptime) else { return }
        requestedFrame = id
        requestedProxy = proxies[id]
        requestSequence += 1
        captureBeganAt = Date()
        requestedBaseSequence = proxies[id]?.acceptedCaptureSequence ?? 0
        requestWindowFrame?(id, requestSequence, requestedBaseSequence)
    }

    func receiveWindowFrame(_ data: Data) {
        // Errors include the request sequence too. Late responses cannot clear
        // a newer request, resurrect a closed window, or cross a Harmony exit.
        guard active, completeWindowCapture, let requested = requestedFrame,
              let newline = data.prefix(100).firstIndex(of: 10) else { return }
        let header = String(decoding: data[..<newline], as: UTF8.self).split(separator: " ")
        guard header.count == 5, Int(header[0]) == requested,
              Int(header[4]) == requestSequence else { return }
        guard !decodingFrame else { return }
        // Keep the request outstanding until publication. There is only one
        // decode in flight, including across exit/re-entry, so no frame backlog.
        let sequence = requestSequence
        let base = requestedProxy.flatMap { proxy -> HarmonyWindowFrame? in
            guard proxy.acceptedCaptureSequence == requestedBaseSequence,
                  let image = proxy.capturedImage else { return nil }
            return HarmonyWindowFrame(id: requested, sequence: requestedBaseSequence, image: image)
        }
        let elapsed = Date().timeIntervalSince(captureBeganAt) * 1000
        decodingFrame = true
        frameDecodeQueue.async { [weak self] in
            let decodeStart = ProcessInfo.processInfo.systemUptime
            let frame = HarmonyWindowFrame.decode(data, base: base)
            let decodeMS = (ProcessInfo.processInfo.systemUptime - decodeStart) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.decodingFrame = false
                guard self.active, self.requestedFrame == requested,
                      self.requestSequence == sequence else {
                    self.requestNextFrame()
                    return
                }
                self.publishWindowFrame(data, frame: frame, header: header.map(String.init), requested: requested, elapsed: elapsed, decodeMS: decodeMS)
            }
        }
    }

    private func publishWindowFrame(_ data: Data, frame: HarmonyWindowFrame?, header: [String], requested: Int, elapsed: Double, decodeMS: Double) {
        let proxy = requestedProxy
        requestedFrame = nil; requestedProxy = nil
        capturedFrameCount += 1
        capturedFrameMilliseconds += elapsed
        decodedFrameMilliseconds += decodeMS
        recentFrameTimings.append((Int(header[3]) == 2, elapsed, data.count))
        if capturedFrameCount % 30 == 0 {
            harmonyDebug(String(format: "PEDECODE meanMS=%.3f worker=serial", decodedFrameMilliseconds / Double(capturedFrameCount)))
            harmonyDebug(String(format: "PEWINDOWFRAME count=%d meanRoundTripMS=%.1f bytes=%d", capturedFrameCount,
                                capturedFrameMilliseconds / Double(capturedFrameCount), data.count))
            let idle = recentFrameTimings.filter { $0.unchanged }
            let full = recentFrameTimings.filter { !$0.unchanged }
            func mean(_ rows: [(unchanged: Bool, milliseconds: Double, bytes: Int)]) -> Double {
                rows.isEmpty ? 0 : rows.reduce(0) { $0 + $1.milliseconds } / Double(rows.count)
            }
            harmonyDebug(String(format: "PEFRAMEBATCH full=%d fullMeanMS=%.1f unchanged=%d unchangedMeanMS=%.1f bytes=%d",
                                full.count, mean(full), idle.count, mean(idle), recentFrameTimings.reduce(0) { $0 + $1.bytes }))
            recentFrameTimings.removeAll(keepingCapacity: true)
        }
        guard let p = proxies[requested], p === proxy else { return }
        let unchanged = Int(header[3]) == 2 && Int(header[1]) == p.capturedImage?.width
            && Int(header[2]) == p.capturedImage?.height && p.hasContents
            && Int(header[1]) == Int(p.guestRect.width) && Int(header[2]) == Int(p.guestRect.height)
            && requestedBaseSequence != 0 && requestedBaseSequence == p.acceptedCaptureSequence
        var accepted = unchanged
        if let frame,
           (Int(header[3]) != 4 || p.acceptedCaptureSequence == requestedBaseSequence),
           Int(p.guestRect.width) == frame.image.width, Int(p.guestRect.height) == frame.image.height {
            let first = !p.hasContents
            p.setOwnImage(frame.image)
            accepted = true
            if first && !p.isMiniaturized {
                p.orderFront(nil)
                // Finder drag images appear as new frontmost CGS windows.
                // Painting one must not steal key focus and release the source's
                // held mouse button through windowDidResignKey.
                if frame.id == focusedGuestWindow && NSApp.isActive && !pointerGestureActive {
                    p.makeKeyAndOrderFront(nil)
                } else if frame.id == focusedGuestWindow && pointerGestureActive {
                    harmonyDebug("PEINPUT deferred surface focus id=\(frame.id) during pointer gesture")
                }
            }
        }
        if accepted {
            reconcileSheets()
            p.acceptedCaptureSequence = requestSequence
            captureScheduler.completed(requested, unchanged: unchanged,
                                       visible: p.occlusionState.contains(.visible),
                                       now: ProcessInfo.processInfo.systemUptime)
            requestNextFrame()
        } else {
            // Keep the last good image visible, but request an independent
            // image next time after any invalid/missing delta base.
            p.acceptedCaptureSequence = 0
            captureScheduler.failed(requested, now: ProcessInfo.processInfo.systemUptime)
        }

        // No timer-sized gap between responses. There is still only one
        // outstanding capture and no queue of obsolete images. Errors wait
        // for the timer rather than spinning on an unsupported window.
    }
    /// Send a point/button/keys to the guest, and raise/move a guest window.
    var sendPoint: ((Int, Int) -> Void)?
    var windowApplications: [Int: Int] = [:] {
        didSet {
            for (id, pid) in windowApplications { proxies[id]?.applicationPid = pid }
        }
    }
    func activateApplication(_ pid: Int) -> Bool {
        // Minimized windows are absent from the guest's on-screen order. Keep
        // their owner on the proxy so its application tile can restore the
        // last remaining window instead of activating an invisible guest app.
        let visible = order.first(where: { windowApplications[$0] == pid }).flatMap { proxies[$0] }
        let minimized = proxies.values.filter { $0.applicationPid == pid && $0.isMiniaturized }
            .sorted { $0.id < $1.id }.first
        guard let proxy = visible ?? minimized else { return false }
        activateProxy(proxy)
        return true
    }
    private var menuFocus = HarmonyMenuFocusIntent()
    func beginMenuFocus() -> String {
        let token = UUID().uuidString
        menuFocus.begin(token: token, now: ProcessInfo.processInfo.systemUptime)
        return token
    }
    func completeMenuFocus(_ token: String, id: Int) {
        guard menuFocus.consume(token: token, now: ProcessInfo.processInfo.systemUptime) else { return }
        guard active, NSApp.isActive,
              let proxy = proxies[id], !proxy.isMiniaturized,
              minimizing[id] == nil, !proxy.restoreIntent.isPending else { return }
        // This acknowledges an explicit menu action, not a periodic guest
        // focus report. Only this window crosses the host's stacking order.
        proxy.makeKeyAndOrderFront(nil)
        captureScheduler.invalidate(id)
        requestNextFrame()
    }

    func activateProxy(_ proxy: HarmonyProxy) {
        guard !proxy.isDragImage else { return }
        NSApp.activate(ignoringOtherApps: true)
        if proxy.isMiniaturized { proxy.deminiaturize(nil) }
        proxy.makeKeyAndOrderFront(nil)
        proxyRaise(proxy.id)
    }
    var requestFocus: ((Int, Int) -> Void)?
    private var focusSequence = 0
    private var pendingFocus: (id: Int, sequence: Int)?
    private var focusEvents: [() -> Void] = []
    private var focusTimeout: DispatchWorkItem?

    private func withFocus(windowID: Int? = nil, _ action: @escaping () -> Void) {
        if let windowID, let child = modalChild(of: windowID) {
            activateProxy(child)
            return // Never replay a blocked document click into its sheet.
        }
        if let windowID, let focus = pendingFocus, focus.id != windowID { return }
        let guardedAction = { [weak self] in
            guard let self else { return }
            if let windowID, self.modalChild(of: windowID) != nil { return }
            if let windowID {
                guard let proxy = self.proxies[windowID], proxy.pendingMove == nil,
                      self.minimizing[windowID] == nil, !proxy.restoreIntent.isPending else { return }
            }
            action()
        }
        if let windowID {
            guard let proxy = proxies[windowID], proxy.pendingMove == nil,
                  minimizing[windowID] == nil, !proxy.restoreIntent.isPending else { return }
        }
        guard pendingFocus != nil else { guardedAction(); return }
        // A gesture belongs to its originating window. Recheck after focus
        // acknowledgment: it may have moved or started minimizing meanwhile.
        if focusEvents.count < 256 { focusEvents.append(guardedAction) }
        else if let focus = pendingFocus { receiveFocus(id: focus.id, sequence: focus.sequence, ok: false) }
    }
    func receiveFocus(id: Int, sequence: Int, ok: Bool) {
        guard pendingFocus?.id == id, pendingFocus?.sequence == sequence else { return }
        focusTimeout?.cancel(); pendingFocus = nil
        let events = focusEvents; focusEvents = []
        guard ok, active, proxies[id] != nil else {
            harmonyDebug("PEFOCUS failed id=\(id)")
            return
        }
        focusedGuestWindow = id
        for event in events { event() }
    }
    func sendProxyButton(_ bit: Int32, _ down: Bool, windowID: Int? = nil) {
        withFocus(windowID: windowID) { [weak self] in self?.sendButton?(bit, down) }
    }
    func sendProxyScroll(_ lines: Int32) {
        withFocus { [weak self] in self?.sendScroll?(lines) }
    }
    func sendProxyKey(_ event: NSEvent) {
        withFocus { [weak self] in self?.forwardKey?(event) }
    }
    var sendButton: ((Int32, Bool) -> Void)?
    var sendScroll: ((Int32) -> Void)?
    /// Take a guest window back out of the guest's Dock.
    var unminimize: ((Int, Int) -> Void)?
    var minimize: ((Int) -> Void)?
    /// Windows told to go into the guest's Dock, and not yet gone.
    private var minimizing: [Int: Date] = [:]
    /// The guest's minimized windows, as last reported.
    var minimizedEntries: [(pid: Int, index: Int, title: String)] = []
    var raiseWindow: ((Int) -> Void)?
    /// Raise a window *and* its application, for the capture pass only.
    var raiseWindowHard: ((Int) -> Void)?
    /// Files let go of over one of the guest's windows.
    var finderWindows = Set<Int>()
    var armFileDrag: ((Int, CGPoint) -> Void)?
    func armDrag(_ id: Int, at point: CGPoint) {
        guard let proxy = proxies[id], let view = proxy.contentView else { return }
        let local = view.convert(proxy.convertPoint(fromScreen: point), from: nil)
        let guest = CGPoint(x: proxy.guestRect.minX + local.x * proxy.guestRect.width / view.bounds.width,
                            y: proxy.guestRect.minY + (view.bounds.height - local.y) * proxy.guestRect.height / view.bounds.height)
        withFocus(windowID: id) { [weak self] in self?.armFileDrag?(id, guest) }
    }
    func pointerOverGuestWindow(_ point: CGPoint) -> Bool {
        var number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        for _ in 0...dragWindows.count {
            guard let proxy = proxies.values.first(where: { $0.windowNumber == number }) else { return false }
            if !proxy.isDragImage { return !proxy.isMenuBar }
            number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: number)
        }
        return false
    }
    var prepareFileDrag: ((Int, @escaping ([NSDraggingItem]) -> Void) -> Void)?
    func beginFileDrag(_ id: Int, completion: @escaping ([NSDraggingItem]) -> Void) {
        withFocus(windowID: id) { [weak self] in
            guard let prepare = self?.prepareFileDrag else { completion([]); return }
            prepare(id, completion)
        }
    }
    var dropPromises: (([NSFilePromiseReceiver], Int) -> Bool)?
    var dropFiles: (([URL], Int) -> Bool)?
    var raiseWindowAt: ((Int, Int, Int) -> Void)?
    var moveWindow: ((Int, Int, Int) -> Void)?
    var moveWindowDrag: ((Int, Int, Int, Int, Int) -> Void)?
    /// Keys from whichever proxy is focused go to the guest through here (the
    /// view's own key handling).
    var forwardKey: ((NSEvent) -> Void)?

    private var proxies: [Int: HarmonyProxy] = [:]
    private var sheetParents: [Int: Int] = [:]
    private var dragWindows: Set<Int> = []
    func setDragWindows(_ ids: Set<Int>) {
        guard active else { return }
        dragWindows = ids
        for (id, proxy) in proxies { proxy.isDragImage = ids.contains(id) }
    }
    private var pointerGestureActive: Bool {
        NSEvent.pressedMouseButtons != 0 || proxies.values.contains {
            ($0.contentView as? HarmonyProxyView)?.hasPointerGesture == true
        }
    }
    func setSheets(_ parents: [Int: Int]) {
        guard active else { return }
        sheetParents = parents.filter { child, parent in
            var seen: Set<Int> = [child]
            var ancestor: Int? = parent
            while let id = ancestor {
                guard seen.insert(id).inserted, seen.count <= 8 else { return false }
                ancestor = parents[id]
            }
            return true
        }
        reconcileSheets()
    }
    func isSheetWindow(_ id: Int) -> Bool { sheetParents[id] != nil }

    /// Return before starting any pointer gesture on a blocked document.
    func redirectBlockedInteraction(_ id: Int) -> Bool {
        guard let child = modalChild(of: id) else { return false }
        releaseInput?()
        activateProxy(child)
        return true
    }
    private func modalChild(of id: Int) -> HarmonyProxy? {
        let child = sheetParents.keys.sorted().first {
            sheetParents[$0] == id && proxies[$0] != nil && vanished[$0] == nil
        }
        guard let child else { return nil }
        return modalChild(of: child) ?? proxies[child]
    }
    private func reconcileSheets() {
        for (id, child) in proxies {
            let parent = sheetParents[id].flatMap { proxies[$0] }
            let attach = vanished[id] == nil && parent.map { vanished[$0.id] == nil } == true && parent?.isMiniaturized == false
                && child.hasContents && !child.isMiniaturized ? parent : nil
            if child.parent !== attach {
                child.parent?.removeChildWindow(child)
                attach?.addChildWindow(child, ordered: .above)
                if let attach, attach.isKeyWindow, NSApp.isActive {
                    releaseInput?()
                    child.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
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
     * across its neighbor.  A window can only be copied cleanly while nothing
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
        /// What was written into the other surface last time.  The pair is
        /// written in turn, so bringing one up to date means re-applying the
        /// previous round's regions as well as this round's.
        var lastRegions: [CGRect] = []
        var front: IOSurfaceRef? { surfaces.isEmpty ? nil : surfaces[1 - back] }
    }
    private var copies: [Int: WindowCopy] = [:]
    /// Which copies were taken with nothing covering the window -- the others
    /// are blank or hold a neighbor's pixels and are waiting to be retaken.
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
    /// Per window, the parts of it something else is drawn over -- asked of the
    /// guest's window server directly, a point at a time.
    private var occluded: [Int: [CGRect]] = [:]
    func setOcclusion(_ o: [Int: [CGRect]]) {
        guard !completeWindowCapture else { return }
        occluded = o
        haveOcclusion = true
        occlReports += 1
        /*
         * Every pixel Harmony shows comes from the frame held here, and this
         * is the only place that frame is taken -- so however fast the card
         * produces frames, no window can refresh more often than the guest
         * sends one of these.  Nothing counted them, which meant the one rate
         * that caps the whole thing was the one rate nobody could see.
         */
        holdTrustedFrame()
        // What the occlusion was worked out for.  The guest sends the window
        // list and then this, on the same tick, so they agree at the moment
        // they are made -- and stop agreeing the instant anything moves.
        occlusionFor = geometryGeneration
    }
    private var occlusionFor = -1

    /*
     * The screen as it was when the guest last said what covered what.
     *
     * The two have never described the same moment.  The guest works out what
     * is drawn over what and sends it; by the time it arrives the card has
     * moved on, and the frame in hand is newer than the answer that is
     * supposed to authorise reading it.  In that gap a window that has just
     * been covered still counts as clear, so it is read -- and what is read
     * where it is covered is the window on top of it.  Measured with two flat
     * colors: 38% of the window underneath was its neighbor, and because the
     * region stays covered afterwards it is never read again, so a mistake
     * lasting one report sits there for the rest of the session.
     *
     * So the frame is kept back.  When an answer arrives, the screen as it
     * stands is put aside, and every window is read from that -- pixels and
     * answer from the same moment, at the cost of showing the guest about a
     * fortieth of a second late, which nobody can see.
     */
    private var trusted: IOSurfaceRef?
    private func holdTrustedFrame() {
        guard let src = surface as! IOSurfaceRef? else { return }
        let w = IOSurfaceGetWidth(src), h = IOSurfaceGetHeight(src)
        guard w > 0, h > 0 else { return }
        if trusted == nil || IOSurfaceGetWidth(trusted!) != w
            || IOSurfaceGetHeight(trusted!) != h {
            let bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4)
            trusted = IOSurfaceCreate([kIOSurfaceWidth: w, kIOSurfaceHeight: h,
                                       kIOSurfaceBytesPerElement: 4,
                                       kIOSurfaceBytesPerRow: bpr,
                                       kIOSurfacePixelFormat: 0x42475241] as CFDictionary)
        }
        guard let dst = trusted else { return }
        IOSurfaceLock(src, .readOnly, nil)
        IOSurfaceLock(dst, [], nil)
        if let sb = IOSurfaceGetBaseAddress(src) as UnsafeMutableRawPointer?,
           let db = IOSurfaceGetBaseAddress(dst) as UnsafeMutableRawPointer? {
            let sbpr = IOSurfaceGetBytesPerRow(src), dbpr = IOSurfaceGetBytesPerRow(dst)
            if sbpr == dbpr {
                memcpy(db, sb, dbpr * h)
            } else {
                let run = min(sbpr, dbpr)
                for y in 0..<h { memcpy(db.advanced(by: y * dbpr),
                                        sb.advanced(by: y * sbpr), run) }
            }
        }
        IOSurfaceUnlock(dst, [], nil)
        IOSurfaceUnlock(src, .readOnly, nil)
    }
    /// Bumped whenever any window's rectangle changes, or one comes or goes.
    private var geometryGeneration = 0
    /// Whether what is known about what covers what describes the screen as it
    /// is now.  Absorbing parts of a window on the strength of a stale answer
    /// is how a window ends up keeping a piece of its neighbor.
    private var occlusionIsCurrent: Bool { occlusionFor == geometryGeneration }
    /*
     * When each window may be read again, as a time rather than a number of
     * reports.  Counting reports tied every one of these waits to how often
     * the guest happens to be reporting: putting that rate up halved them all
     * at a stroke, and the desktop started showing through windows as they
     * were dropped.
     */
    private var quietUntil: [Int: Date] = [:]
    private func settle(_ id: Int, _ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        if (quietUntil[id] ?? .distantPast) < until { quietUntil[id] = until }
    }
    private func isSettled(_ id: Int) -> Bool {
        Date() >= (quietUntil[id] ?? .distantPast)
    }
    /*
     * Hold every window still for a moment.
     *
     * For the things the guest does to its whole screen at once, which no
     * amount of asking about windows will reveal.  A minimize is the one that
     * matters: the genie is drawn by the window server itself and is not a
     * window at all, so asking what is drawn at a point inside it answers
     * "nothing in particular" -- which reads as clear, and every window the
     * smear passes over copies a piece of it and keeps it.  That is a whole
     * desktop of contaminated surfaces from one click, and it cannot be seen
     * coming; it can only be waited out.
     */
    /*
     * Why a window is not being copied.
     *
     * Every reason a copy is skipped is counted and said out loud once a
     * second.  Guessing at this from the outside is hopeless -- "the surface
     * takes ten seconds to update" is the same symptom for five quite
     * different causes, and each of the waits below was put there to fix
     * something real.  The numbers say which one is actually holding, and
     * whether it is holding for a frame or for thousands of them.
     */
    /*
     * The last full second's figures, kept so the overlay can show them.
     *
     * The same numbers go to the log, but nobody reading a window that will
     * not update wants to be told to go and read a log: the useful moment for
     * these is while the thing is happening, on the screen where it is
     * happening, where a screenshot carries the whole story.
     */
    struct Diagnostics {
        var fps = 0.0, copies = 0, windows = 0
        var stale = 0, settling = 0, notFresh = 0, covered = 0, noDamage = 0
        var pointerSent = 0, pointerDropped = 0, clicks = 0, occlPerSec = 0, desktopSkips = 0
        var olderThan2s = 0, worstAge = 0.0
        var publishedSeq = 0, worstSeqLag = 0
        var inSync = true
    }
    private(set) var diag = Diagnostics()
    /// The frame each window's picture was taken from, and the newest frame
    /// seen.  The gap between them is how far behind a window actually is,
    /// counted in frames rather than in seconds since something was copied.
    var currentFrameSeq = 0
    private var copiedAtSeq: [Int: Int] = [:]

    private var gateStale = 0, gateSettle = 0, gateFresh = 0, gateNoOccl = 0
    private var gateCovered = 0, gateFocus = 0, gateCopied = 0, gateNoDamage = 0
    /// Regions refused because the card called them desktop.  This is the one
    /// gate with no timer and no bound: nothing retries, so a window it turns
    /// away stays exactly as it was.
    private var gateDesktop = 0
    private var gatesSaid = Date()
    private var lastCopied: [Int: Date] = [:]
    private var framesAtReport = 0
    private var fullCopyGen: [Int: Int] = [:]
    private var gaveUpAt = Date()
    private var occlReports = 0
    /*
     * Say the figures on a clock of their own.
     *
     * This used to be called from the frame path, so the counters were "since
     * the last print" and the print only happened when a frame arrived -- and
     * they were labeled per second regardless.  When frames dried up the
     * interval stretched to seventeen seconds and every rate read seventeen
     * times too high: an occlusion rate of 24 a second was shown as 418, which
     * sent me hunting a memory-bandwidth problem that did not exist.  The one
     * moment the numbers are worth having is the moment nothing is arriving,
     * which was exactly when they lied.
     */
    private var gateTimer: Timer?
    private func startGateReporting() {
        gateTimer?.invalidate()
        gateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportGates(force: true) }
        }
    }
    private func stopGateReporting() { gateTimer?.invalidate(); gateTimer = nil }

    private func reportGates(force: Bool = false) {
        // Only the timer publishes; the frame path just accumulates.
        guard force else { return }
        guard Date().timeIntervalSince(gatesSaid) >= 0.5 else { return }
        let prevSaid = gatesSaid
        let secs = max(0.001, Date().timeIntervalSince(prevSaid))
        gatesSaid = Date()
        defer { framesAtReport = frames }
        /*
         * How old the picture on screen actually is, per window, which is the
         * thing anybody watching this complains about.  A copy rate averaged
         * over all the windows hides exactly the case that hurts: most of them
         * fresh and one of them ten seconds behind.
         */
        let now = Date()
        let ages = proxies.keys.map { now.timeIntervalSince(lastCopied[$0] ?? now) }
        let worst = ages.max() ?? 0
        let stale2 = ages.filter { $0 > 2 }.count
        NSLog("PEGATE fps=%.1f copied=%d | stalepass=%d settling=%d notfresh=%d nooccl=%d covered=%d justfocus=%d nodamage=%d | pointer sent=%d dropped=%d clicks=%d | occl=%d/s maskskip=%d | windows=%d older2s=%d worstage=%.1fs gen=%d occlfor=%d",
              Double(frames - framesAtReport) / max(0.001, Date().timeIntervalSince(prevSaid)),
              gateCopied, gateStale, gateSettle, gateFresh, gateNoOccl,
              gateCovered, gateFocus, gateNoDamage, pointSends, pointDrops, clicksSent, occlReports, gateDesktop,
              proxies.count, stale2, worst,
              geometryGeneration, occlusionFor)
        gateStale = 0; gateSettle = 0; gateFresh = 0; gateNoOccl = 0
        diag = Diagnostics(
            fps: Double(frames - framesAtReport) / secs,
            copies: Int(Double(gateCopied) / secs), windows: proxies.count,
            stale: gateStale, settling: gateSettle, notFresh: gateFresh,
            covered: gateCovered, noDamage: gateNoDamage,
            pointerSent: Int(Double(pointSends) / secs), pointerDropped: Int(Double(pointDrops) / secs),
            clicks: clicksSent,
            occlPerSec: Int(Double(occlReports) / secs), desktopSkips: gateDesktop,
            olderThan2s: stale2, worstAge: worst,
            publishedSeq: currentFrameSeq,
            worstSeqLag: proxies.keys.map { currentFrameSeq - (copiedAtSeq[$0] ?? currentFrameSeq) }.max() ?? 0,
            inSync: occlusionFor == geometryGeneration)
        gateCovered = 0; gateFocus = 0; gateCopied = 0; gateNoDamage = 0
        pointSends = 0; pointDrops = 0; occlReports = 0; gateDesktop = 0
        dumpProxySurfaces()
    }

    /*
     * Write out what each window's picture actually contains.
     *
     * "Still a lot of corruption" and "it looks fine to me" are the same
     * sentence with different eyes behind it, and neither can be acted on.
     * With windows of a known flat color in the guest, every pixel in a
     * proxy's surface that is not that window's color is a pixel that came
     * from somewhere else, and contamination stops being an impression and
     * becomes a count.  POWEREMU_HARMONY_DUMP=1; raw BGRA into /tmp, with the
     * guest rect in the name so the analysis knows what overlapped what.
     */
    private func dumpProxySurfaces() {
        guard ProcessInfo.processInfo.environment["POWEREMU_HARMONY_DUMP"] != nil else { return }
        dumpNow()
    }
    /// Every frame rather than once a second, for timing how long something
    /// takes to appear.  A second's granularity cannot measure a budget of a
    /// tenth of one.
    private func dumpEveryFrameIfAsked() {
        guard ProcessInfo.processInfo.environment["POWEREMU_HARMONY_DUMP"] == "all" else { return }
        dumpNow()
    }
    private func dumpNow() {
        for (id, p) in proxies {
            guard let s = copies[id]?.lastGood ?? copies[id]?.front else { continue }
            let w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s)
            let bpr = IOSurfaceGetBytesPerRow(s)
            IOSurfaceLock(s, .readOnly, nil)
            defer { IOSurfaceUnlock(s, .readOnly, nil) }
            guard let base = IOSurfaceGetBaseAddress(s) as UnsafeMutableRawPointer? else { continue }
            var head = "\(w) \(h) \(bpr) \(Int(p.guestRect.minX)) \(Int(p.guestRect.minY))\n"
            var d = Data(head.utf8)
            d.append(Data(bytes: base, count: bpr * h))
            try? d.write(to: URL(fileURLWithPath: "/tmp/peproxy-\(id).bin"))
            head = ""
        }
    }

    private func settleAll(_ seconds: TimeInterval) {
        for id in proxies.keys { settle(id, seconds) }
    }
    /// Whether the guest has answered about occlusion at all yet.  Until it
    /// has, "no rectangles" cannot be told from "not asked".
    private var haveOcclusion = false
    /// Show each window's visible part live from the guest's screen, over its
    /// own stored copy.  Off by default while it is being worked on: with it
    /// off, every window shows only its own complete copy, which is the
    /// behavior that works.
    /// Absorb only the freshly drawn, uncovered parts of every window, rather
    /// than copying the one in front whole.  See refreshLiveCopies.
    /*
     * Copy only the parts of a window nothing is drawn over, rather than
     * refusing to copy a window that anything is drawn over.
     *
     * Measured, the refusal is not a delay -- it is permanent.  With five
     * windows on screen, four of them overlapped by something, the whole-window
     * path copied one of them and let the other four go on ageing without
     * limit: thirty-five seconds and climbing, every gate except "covered"
     * reading zero.  A window is disqualified by a single covered pixel and
     * there is nothing to bring it back but the user happening to clear it.
     *
     * POWEREMU_HARMONY_PARTS=0 goes back to whole windows.
     */
    var liveAbsorb = ProcessInfo.processInfo.environment["POWEREMU_HARMONY_PARTS"] != "0"
    var liveMasking = false {
        didSet { if !liveMasking { for p in proxies.values { p.hideLive() } } }
    }

    /// A window's rectangle less the parts covered, in its own coordinates.
    private func visibleParts(_ id: Int, _ g: CGRect) -> [CGRect] {
        var parts = [CGRect(x: 0, y: 0, width: g.width, height: g.height)]
        for o in occluded[id] ?? [] {
            let cut = CGRect(x: o.minX - g.minX, y: o.minY - g.minY, width: o.width, height: o.height)
            var next: [CGRect] = []
            for r in parts {
                guard r.intersects(cut) else { next.append(r); continue }
                // What is left of this rectangle once the covered part is out.
                if cut.minY > r.minY { next.append(CGRect(x: r.minX, y: r.minY, width: r.width, height: cut.minY - r.minY)) }
                if cut.maxY < r.maxY { next.append(CGRect(x: r.minX, y: cut.maxY, width: r.width, height: r.maxY - cut.maxY)) }
                let top = max(r.minY, cut.minY), bot = min(r.maxY, cut.maxY)
                if bot > top {
                    if cut.minX > r.minX { next.append(CGRect(x: r.minX, y: top, width: cut.minX - r.minX, height: bot - top)) }
                    if cut.maxX < r.maxX { next.append(CGRect(x: cut.maxX, y: top, width: r.maxX - cut.maxX, height: bot - top)) }
                }
            }
            parts = next
            if parts.isEmpty { break }
        }
        return parts.filter { $0.width >= 1 && $0.height >= 1 }
    }

    var focusedGuestWindow = 0 {
        didSet {
            /*
             * Only a real change of window restarts the wait.  Asking the guest
             * to raise something clears this to nothing until the guest answers,
             * and treating that as a change restarted the wait twice per raise
             * -- and on a busy desktop often faster than it could ever finish.
             */
            guard focusedGuestWindow != 0, focusedGuestWindow != oldValue else { return }
            framesSinceFocus = 0
            focusChangedAt = Date()
            /*
             * This used to invalidate the occlusion as well, on the grounds
             * that a window coming forward changes what covers what without
             * moving anything.  True, but the answer does not need
             * invalidating: the guest works out what covers what by asking the
             * window server where things are drawn, live, at the moment it
             * reports -- so the answer it sends already has the raise in it.
             *
             * Invalidating anyway was worse than useless.  Focus is reported
             * after the occlusion in every report, so each focus change left
             * the occlusion one generation behind; with focus moving between
             * two windows it never caught up, "still current" was never true
             * again, and the copy path stopped dead -- measured at fps=0.0,
             * copied=0, every window frozen with gen one ahead of occlfor for
             * as long as it was watched.
             *
             * The window that was just raised is still held for a moment
             * below, which is the part that was actually needed: the guest has
             * restacked it but not yet repainted it.
             */
        }
    }
    private var focusChangedAt = Date.distantPast
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
    private var captureReady = false
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

    /// Complete-window mode maps one guest pixel to one logical host point.
    /// The legacy masked fallback retains its width-based scale.
    private var scale: CGFloat { completeWindowCapture ? 1 : (guestSize.width > 0 ? screenFrame.width / guestSize.width : 1) }
    private var coordinates: HarmonyCoordinates { HarmonyCoordinates(screen: screenFrame, topInset: offsetY) }
    /// How far below the top of the screen the guest starts, so its menu bar's
    /// bottom lines up with this Mac's taller menu bar.
    private var offsetY: CGFloat { max(0, hostMenuBar - guestMenuBar * scale) }

    func setActive(_ on: Bool, screenFrame: CGRect, guestSize: CGSize, hostMenuBar: CGFloat) {
        windowFrameTimer?.invalidate(); windowFrameTimer = nil
        requestedFrame = nil; requestedProxy = nil
        captureScheduler = HarmonyCaptureScheduler()
        menuFocus.cancel()
        pendingFocus = nil; focusEvents = []; focusTimeout?.cancel()
        active = on
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        keyWindowObserver = nil
        if on {
            keyWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.onGuestWindowFocus?(notification.object is HarmonyProxy) }
            }
        } else { onGuestWindowFocus?(false) }
        if on { startGateReporting() } else { stopGateReporting() }
        self.screenFrame = screenFrame
        self.guestSize = guestSize
        self.hostMenuBar = hostMenuBar
        if on {
            startPointerTracking()
            if completeWindowCapture {
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.requestNextFrame() }
                }
                RunLoop.main.add(timer, forMode: .common)
                windowFrameTimer = timer
            }
        } else {
            stopPointerTracking()
            sheetParents = [:]; dragWindows = []
            for p in proxies.values { p.parent?.removeChildWindow(p) }
            for p in proxies.values { p.orderOut(nil) }; proxies = [:]; order = []
            menuBar?.orderOut(nil); menuBar = nil
            copies = [:]; cleanSnapshots = []; fresh = [:]; lastRect = [:]; wasCovered = [:]
            occluded = [:]; haveOcclusion = false; quietUntil = [:]
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
        if completeWindowCapture { return } // proxy events carry their own screen position
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
    func refreshLiveCopies(damaged: CGRect) {
        guard active, !completeWindowCapture else { return }
        frames += 1
        /*
         * Every window, not just the one in front.
         *
         * A pixel is absorbed into a window's picture only where all three of
         * these hold: the guest says nothing is drawn over it, the guest has
         * just drawn there, and the pixel belongs to a window rather than the
         * desktop.  The first says the pixel is this window's to read; the
         * second says the guest has actually painted it, which is what the
         * various waits and probations were guessing at; the third keeps the
         * desktop out when a window has gone but the report has not caught up.
         *
         * Because that holds for any window, not merely the front one, a
         * window behind can keep its clock, its progress bar and its game
         * moving -- which copying only the front window could never do.
         */
        /*
         * Off by default.  Absorbing only the drawn, uncovered parts is the
         * right design and makes every window live, but it depends on the
         * occlusion report being exactly right at the instant of the frame --
         * and when it is not, the window quietly keeps a piece of its
         * neighbor for good.  Until that is trustworthy, one window is copied
         * whole, which can only ever be right or old, never wrong.
         */
        /*
         * Only while what is known about what covers what still describes the
         * screen.  The guest works that out and sends it with the window list;
         * the moment a window moves, the answer describes a screen that no
         * longer exists, and absorbing a part of a window on the strength of it
         * is exactly how the window ends up keeping a piece of its neighbor --
         * for good, because nothing afterwards knows to put it right.
         */
        dumpEveryFrameIfAsked()
        guard !liveAbsorb || occlusionIsCurrent else { gateStale += 1; reportGates(); return }
        guard liveAbsorb else {
            /*
             * Every window nothing is drawn over, not merely the focused one.
             *
             * A window the guest says is wholly clear can be read straight out
             * of the frame: what is there is its own pixels, whoever happens to
             * have the keyboard.  Copying only the one believed to be focused
             * meant a progress bar filling in a dialog, or a piece lighting up
             * in a game, went unseen whenever that window was not the one we
             * thought was in front -- and what we think is in front is itself
             * only a guess the guest sends us.
             *
             * Still whole windows only.  Reading part of a window is what
             * leaves a piece of its neighbor behind, and that is what is
             * waiting on being able to trust the occlusion completely.
             */
            /*
             * And only while what is known about what covers what still
             * describes this screen.  Copying a window on a stale answer is
             * how it ends up holding a piece of its neighbor -- which is what
             * reading *every* clear window rather than only the focused one
             * made far more likely, because there are simply more of them
             * being read at any moment.
             */
            guard occlusionIsCurrent else { gateStale += 1; reportGates(); return }
            for (id, p) in proxies where !p.isMiniaturized {
                if !isSettled(id) { gateSettle += 1; continue }
                if fresh[id, default: 0] < 3 { gateFresh += 1; continue }
                if !haveOcclusion { gateNoOccl += 1; continue }
                if !(occluded[id] ?? []).isEmpty { gateCovered += 1; continue }
                // Just after a window takes focus the guest has restacked it
                // but not yet repainted it.
                if id == focusedGuestWindow,
                   Date().timeIntervalSince(focusChangedAt) <= 0.2 { gateFocus += 1; continue }
                if let snap = snapshot(id, p.guestRect, regions: nil) {
                    p.setOwnSurface(snap)
                    copyCount += 1
                    gateCopied += 1
                    lastCopied[id] = Date(); copiedAtSeq[id] = currentFrameSeq
                }
            }
            reportGates()
            return
        }
        for (id, p) in proxies where !p.isMiniaturized {
            if fresh[id, default: 0] < 3 { gateFresh += 1; continue }
            let g = p.guestRect
            /*
             * The window being worked in is read on every frame, whatever the
             * card says was drawn.
             *
             * Everything else here waits to be told that something changed,
             * which is right for the windows nobody is touching -- and quite
             * wrong for the one that is.  Deciding what changed depends on the
             * card noticing every write to video memory, and it does not
             * notice all of them: the renderer reaches memory through a shared
             * buffer that marks nothing, so what it draws is only caught by a
             * sweep twice a second.  For a window in the background that is a
             * fair trade.  For the window whose selection the reader is
             * waiting to see, it is the difference between a program that
             * works and one that does not.
             *
             * One window's worth of copying per frame is a price worth paying
             * to never have to explain why the thing under the pointer is the
             * last thing to move.
             */
            if id == focusedGuestWindow, !g.isEmpty,
               Date().timeIntervalSince(focusChangedAt) > 0.2 {
                let regions = visibleParts(id, g)
                // Its visible parts come from an answer that still describes
                // this screen, so they are this window's to read whatever the
                // card's own guess about desktop-versus-window says.
                let trust = occlusionIsCurrent && haveOcclusion
                if !regions.isEmpty,
                   let snap = snapshot(id, g, regions: regions, trustRegions: trust) {
                    p.setOwnSurface(snap)
                    lastCopied[id] = Date(); copiedAtSeq[id] = currentFrameSeq
                    gateCopied += 1; copyCount += 1
                    continue
                }
            }
            /*
             * A window nothing covers is read whole now and then, even though
             * nothing has been drawn in it.
             *
             * Copying only what the guest has just drawn is what keeps a
             * window behind alive, but it also means a window that has stopped
             * drawing is never read again -- and if anything wrong ever got
             * into its picture, it stays there for good.  Something wrong does
             * get in: the guest's answer about what covers what arrives a
             * frame or so after the frame it describes, so a window can be
             * read as clear in the moment another is already drawn over it.
             * Measured, that left a window 40% made of its neighbor, sitting
             * there unchanged while it was fully visible and uncovered,
             * because a flat window draws nothing and nothing was ever
             * re-read.  The whole-window path healed this by accident; this
             * one has to do it on purpose.
             */
            /*
             * Read whole when something has actually changed about the window,
             * not merely because time has passed.
             *
             * This used to fire once a second regardless, which is the one
             * thing the brief forbids: an unchanged picture is not stale
             * because it is old, and copying the same pixels again is not
             * progress.  It was there to heal windows that had absorbed a
             * neighbor during the gap between a frame and the answer
             * describing it -- and that gap is now closed at its source, by
             * reading from the frame the guest has already answered about.
             *
             * What is left is the case where the window's own circumstances
             * moved: it was uncovered, or resized, or restacked.  Then the
             * parts that could not be read before can be read now, and the
             * whole is worth taking once.  The generation counter says when
             * that happened; the clock never did.
             */
            if (occluded[id] ?? []).isEmpty, haveOcclusion, occlusionIsCurrent,
               isSettled(id),
               fullCopyGen[id] != geometryGeneration {
                if let snap = snapshot(id, g, regions: nil) {
                    p.setOwnSurface(snap)
                    fullCopyGen[id] = geometryGeneration
                    lastCopied[id] = Date()
                    copiedAtSeq[id] = currentFrameSeq
                    gateCopied += 1; copyCount += 1
                }
                continue
            }
            let hit = damaged.intersection(g)
            guard !hit.isNull, hit.width >= 1, hit.height >= 1 else { gateNoDamage += 1; continue }
            // In the window's own coordinates, and only where it is not covered.
            var regions: [CGRect] = []
            for v in visibleParts(id, g) {
                let local = CGRect(x: hit.minX - g.minX, y: hit.minY - g.minY,
                                   width: hit.width, height: hit.height).intersection(v)
                if !local.isNull, local.width >= 1, local.height >= 1 { regions.append(local) }
            }
            guard !regions.isEmpty else { gateCovered += 1; continue }
            if let snap = snapshot(id, g, regions: regions) {
                lastCopied[id] = Date(); copiedAtSeq[id] = currentFrameSeq; gateCopied += 1
                p.setOwnSurface(snap)
                copyCount += 1
            }
        }
        reportGates()
    }

    /// Why the window in front was not copied, since the last report.
    private var frames = 0, skipNoFront = 0, skipTooSoon = 0, skipCovered = 0
    /// Copies made of the window in front, and when counting started.
    private var copyCount = 0
    private var copyCountSince = Date()
    /// How often the window in front is actually being copied.
    func copyRate() -> String {
        let dt = Date().timeIntervalSince(copyCountSince)
        let r = dt > 0 ? Double(copyCount) / dt : 0
        let out = String(format: "PERATE %.1f copies/s over %.1fs (front=%d fresh=%d capturing=%d) "
                         + "frames=%d nofront=%d toosoon=%d covered=%d",
                         r, dt, focusedGuestWindow, fresh[focusedGuestWindow, default: -99],
                         capturing ? 1 : 0, frames, skipNoFront, skipTooSoon, skipCovered)
        copyCount = 0; copyCountSince = Date()
        frames = 0; skipNoFront = 0; skipTooSoon = 0; skipCovered = 0
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
    /*
     * Which guest screen a rectangle is on, and where it sits on it.
     *
     * The guest reports every window in one desktop coordinate space, so a
     * window on the second screen is simply one whose origin lies past the
     * first screen's width.  That needs no knowledge of how the reader has
     * arranged the screens in Displays: anything outside screen 1 is on
     * another screen, whichever side they put it.
     *
     * Harmony turns guest windows into windows on *this* Mac, and on a Mac
     * with one screen there is one place for them to go, so a window from
     * the second guest screen is folded back by a screen's width rather than
     * being left off the edge -- which is what used to happen to it, via
     * onScreen() below, so it was never refreshed at all.  Its guest
     * position is untouched, so leaving Harmony puts it back where it was.
     */
    private func foldIntoPrimary(_ g: CGRect) -> CGRect {
        guard guestSize.width > 0 else { return g }
        var r = g
        while r.minX >= guestSize.width { r.origin.x -= guestSize.width }
        while r.maxX <= 0 { r.origin.x += guestSize.width }
        return r
    }

    /// True when this rectangle belongs to a guest screen other than the first.
    func isOnSecondaryGuestScreen(_ g: CGRect) -> Bool {
        guestSize.width > 0 && (g.minX >= guestSize.width || g.maxX <= 0)
    }

    private func hostFrame(_ g0: CGRect) -> CGRect {
        let g = foldIntoPrimary(g0)
        if completeWindowCapture { return coordinates.hostRect(g) }
        let s = scale
        return CGRect(x: screenFrame.minX + g.minX * s,
                      y: screenFrame.maxY - (offsetY + (g.minY + g.height) * s),
                      width: g.width * s, height: g.height * s)
    }

    /// The host rectangle a guest window maps to (for diagnostics).
    func hostFrameFor(_ g: CGRect) -> CGRect { hostFrame(g) }

    func hostStackReport() -> String {
        let nativeIDs = Dictionary(uniqueKeysWithValues: proxies.map { ($0.value.windowNumber, $0.key) })
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { row -> String? in
            guard let number = row[kCGWindowNumber as String] as? Int,
                  (row[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            if let guest = nativeIDs[number] { return "guest:\(guest)(native:\(number))" }
            guard (row[kCGWindowOwnerName as String] as? String) == "Finder" else { return nil }
            return "host:Finder(native:\(number))"
        }.joined(separator: " > ")
    }

    /// What each proxy window actually is on screen, for diagnosing a Harmony
    /// that draws nothing.
    func proxyReport() -> String {
        let source = completeWindowCapture ? "source=complete captureCount=\(capturedFrameCount) pending=\(requestedFrame ?? 0) " : "source=screen "
        return source + proxies.map { id, p in
            let f = p.frame
            return "\(id):frame=(\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height)))"
                 + ",vis=\(p.isVisible ? 1 : 0),a=\(String(format: "%.2f", p.alphaValue))"
                 + ",contents=\(p.hasContents ? 1 : 0),lvl=\(p.level.rawValue)"
                 + ",sheetParent=\(sheetParents[id] ?? 0),attachedTo=\((p.parent as? HarmonyProxy)?.id ?? 0),dragImage=\(p.isDragImage ? 1 : 0)"
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
            // Horizontally this now asks "is it on *a* guest screen", not "is
            // it on the first one": with two screens the second one's windows
            // are past the first's width, and dropping them here is why they
            // never refreshed.  The vertical test is unchanged -- the Dock's
            // icons really do sit below the desktop while it is hidden.
            let f = foldIntoPrimary(r)
            return r.maxY > 0 && r.minY < guestSize.height
                && f.maxX > 0 && f.minX < guestSize.width
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
        if nowShown != Set(lastRect.keys) || shown.contains(where: { lastRect[$0.id] != $0.rect }) {
            geometryGeneration &+= 1
        }
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
                n.applicationPid = windowApplications[w.id]
                n.isDragImage = dragWindows.contains(w.id)
                // Nothing to show until this window has been copied: better
                // empty for a frame than the whole desktop.
                proxies[w.id] = n
                if !completeWindowCapture { n.orderFront(nil) }
                return n
            }()
            /*
             * Still on screen -- but not necessarily still wanted there.
             *
             * When the yellow button is pressed on this side, this Mac puts the
             * proxy in its Dock at once while the guest's window carries on
             * exactly as it was, so the very next report said "still here" and
             * pulled the proxy straight back out.  That is the window bouncing
             * out of the Dock.  The guest has now been asked to minimize the
             * real window, so the proxy stays down until it does, or until it
             * is clear it never will.
             */
            if p.isMiniaturized && !p.restoreIntent.isPending {
                if let asked = minimizing[w.id] {
                    if Date().timeIntervalSince(asked) < 3 { continue }
                    minimizing.removeValue(forKey: w.id)   // the guest would not
                }
                p.deminiaturize(nil); p.minimizedPid = nil
            }
            let restored = p.restoreIntent.canAcknowledgeVisible
            if restored {
                p.restoreIntent.acknowledgeVisible()
                p.minimizedPid = nil
                p.minimizedBaseline = nil
                minimizing.removeValue(forKey: w.id)
            }
            if vanished.removeValue(forKey: w.id) != nil {
                minimizing.removeValue(forKey: w.id)
                p.minimizedBaseline = nil
                p.orderFront(nil)
            }
            p.guestRect = w.rect
            if restored && p.isKeyWindow { proxyRaise(p.id) }
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
                settle(w.id, 0.5)       // resizing is the slowest to catch up
            }
            else if was != w.rect || wasCovered[w.id] != cov {
                fresh[w.id] = 0
                settle(w.id, 0.25)
            }
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
            if completeWindowCapture {
                // Complete frames are published only by receiveWindowFrame.
            } else if let have = copies[w.id]?.front ?? copies[w.id]?.lastGood {
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
             * away -- which a minimized window never takes.  Its last rectangle
             * then stayed in `lastRect` for the rest of the session, and the
             * "something moved here" list below re-added it on every report,
             * so every window overlapping where it used to be was held on
             * probation for ever and never copied again.
             */
            fresh.removeValue(forKey: id); lastRect.removeValue(forKey: id)
            wasCovered.removeValue(forKey: id); captureMisses.removeValue(forKey: id)
            quietUntil.removeValue(forKey: id)
            /*
             * A window that has gone from the guest's screen has either been
             * closed or put in the guest's Dock -- and the guest's Dock is
             * hidden, so a minimized window would be gone for good.  Minimize
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
                settleAll(0.8)          // it may have been a minimize: let it finish
                // Only a window that goes into the Dock *after* this one left
                // the screen can be this one.  Matching against whatever was
                // already minimized gave the first window the user closed
                // somebody else's Dock entry, and left it there for good.
                if p.minimizedBaseline == nil {
                    p.minimizedBaseline = Set(minimizedEntries.map { "\($0.pid)/\($0.index)" })
                }
            }
            if p.minimizedPid == nil, let e = unboundMinimized(for: p) {
                p.minimizedPid = e.pid
                p.minimizedIndex = e.index
                p.title = e.title.isEmpty ? "Virtual Mac window" : e.title
                /*
                 * No genie.  The guest has already played its own minimize
                 * into a Dock that is hidden, so a second animation here is
                 * both wrong and late; the window should simply be in the
                 * Dock.  The Dock's effect is a setting of this Mac's that is
                 * not ours to change, so the window is told not to animate
                 * instead.
                 */
                p.animationBehavior = .none
                // miniaturize() does nothing to these windows; performMiniaturize
                // is the one that puts them in the Dock.
                if p.restoreIntent.bind() {
                    // Keep this binding until WINDOWS confirms visibility.
                    // An older minimized report must not initiate a new minimize.
                    unminimize?(e.pid, e.index)
                } else if !p.restoreIntent.isPending && !p.isMiniaturized { p.performMiniaturize(nil) }
                continue
            }
            // During restore the guest may still report this window as absent.
            // Preserve the host window and binding throughout that interval.
            if p.restoreIntent.isPending || p.minimizedPid != nil || p.isMiniaturized { continue }
            // AX's minimized report can arrive well after the geometry report.
            // Hide a disappeared window immediately but retain its image and
            // identity long enough to bind the later Dock entry.
            p.orderOut(nil)
            if let since = vanished[id], Date().timeIntervalSince(since) < 2 { continue }
            vanished.removeValue(forKey: id)
            p.orderOut(nil); proxies.removeValue(forKey: id)
            copies.removeValue(forKey: id); cleanSnapshots.remove(id)
        }
        if completeWindowCapture {
            order = shown.map { $0.id }
            reconcileSheets()
            requestNextFrame()
            return
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
        /*
         * Nothing is given up on for ever.
         *
         * A window that could not be caught three times running used to be
         * abandoned for the rest of the session, and the stricter rule for
         * taking a picture -- the guest must say nothing at all covers it --
         * makes missing far easier than it was.  A window abandoned that way
         * never gets a complete picture, so wherever anything is drawn over it
         * there is nothing to fall back on and the gap simply stays: a hole in
         * the window where its neighbor overlaps, for as long as it is open.
         * Measured from the overlay, one window at ninety-nine seconds without
         * a copy while every other figure was healthy.  So the slate is wiped
         * every half minute and they are tried again.
         */
        if Date().timeIntervalSince(gaveUpAt) > 30 {
            gaveUpAt = Date()
            if !gaveUp.isEmpty {
                harmonyDebug("PECAP retrying \(gaveUp.count) given up on")
                gaveUp.removeAll()
                for id in captureMisses.keys { captureMisses[id] = 0 }
            }
        }
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
    /// Absorb the given parts of a window (in its own coordinates) into its
    /// stored picture.  Passing nil takes the whole window, for the pass that
    /// raises one to read it clear.
    private func snapshot(_ id: Int, _ g: CGRect, regions: [CGRect]?,
                          trustRegions: Bool = false) -> IOSurfaceRef? {
        let w = Int(g.width.rounded()), h = Int(g.height.rounded())
        guard w > 0, h > 0 else { return copies[id]?.front }
        let c = copies[id] ?? { let n = WindowCopy(); copies[id] = n; return n }()
        if c.surfaces.count != 2 || IOSurfaceGetWidth(c.surfaces[0]) != w
            || IOSurfaceGetHeight(c.surfaces[0]) != h {
            cleanSnapshots.remove(id)
            let bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4)
            let props: [CFString: Any] = [kIOSurfaceWidth: w, kIOSurfaceHeight: h,
                                          kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: bpr,
                                          kIOSurfacePixelFormat: 0x42475241 /* 'BGRA' */]
            c.surfaces = (0..<2).compactMap { _ in IOSurfaceCreate(props as CFDictionary) }
            /*
             * Start opaque.
             *
             * A new surface is all zeroes, and zero alpha is see-through.  The
             * parts of a window that are covered are never read -- there is
             * nothing on the screen to read them from -- so on a window that
             * has just appeared, or just been resized, those parts keep the
             * zeroes they were born with and the reader sees their own desktop
             * through the middle of a guest window.  Opaque is the honest
             * starting state: it shows that nothing is known there yet, rather
             * than pretending there is a hole.
             */
            for s in c.surfaces {
                IOSurfaceLock(s, [], nil)
                if let b = IOSurfaceGetBaseAddress(s) as UnsafeMutableRawPointer? {
                    memset(b, 0, IOSurfaceGetBytesPerRow(s) * IOSurfaceGetHeight(s))
                    var o = 3
                    let end = IOSurfaceGetBytesPerRow(s) * IOSurfaceGetHeight(s)
                    while o < end { b.storeBytes(of: UInt8(0xff), toByteOffset: o, as: UInt8.self); o += 4 }
                }
                IOSurfaceUnlock(s, [], nil)
            }
            c.back = 0
            c.lastRegions = []
            guard c.surfaces.count == 2 else { return c.lastGood }
        }
        // The held frame, which the guest has already answered about; only
        // the live one if no answer has ever arrived.
        guard let src = trusted ?? (surface as! IOSurfaceRef?) else { return c.front }
        let whole = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let mine = regions ?? [whole]
        /*
         * The two surfaces are written in turn, so the one being written has to
         * be brought up to date wherever this round does not reach, or the
         * window alternates between two moments of itself.
         *
         * It used to be brought up to date by reading the previous round's
         * rectangles out of the desktop again, which is a different thing and
         * a dangerous one: a patch that was this window last round may be
         * another window by now.  Uncover a window, let something slide over
         * the part that just changed, and the next update copies the neighbor
         * into it -- and calls it synchronizing.  Old damage says a patch was
         * once ours; it never says it still is.
         *
         * So the surface is brought up to date from the picture it is meant to
         * follow -- the one on screen, which was valid when it was published --
         * and only this round's validated rectangles are read from the guest.
         */
        let apply = mine
        let sw = IOSurfaceGetWidth(src), sh = IOSurfaceGetHeight(src)
        let gx = Int(g.minX.rounded()), gy = Int(g.minY.rounded())
        let dst = c.surfaces[c.back]

        IOSurfaceLock(src, .readOnly, nil)
        IOSurfaceLock(dst, [], nil)
        let sb = IOSurfaceGetBaseAddress(src), db = IOSurfaceGetBaseAddress(dst)
        let sbpr = IOSurfaceGetBytesPerRow(src), dbpr = IOSurfaceGetBytesPerRow(dst)
        var wrote = false
        if regions != nil, let prev = c.lastGood ?? c.front,
           IOSurfaceGetWidth(prev) == w, IOSurfaceGetHeight(prev) == h, prev !== dst {
            IOSurfaceLock(prev, .readOnly, nil)
            if let pb = IOSurfaceGetBaseAddress(prev) as UnsafeMutableRawPointer? {
                let pbpr = IOSurfaceGetBytesPerRow(prev)
                let run = min(pbpr, dbpr)
                for row in 0..<h {
                    memcpy(db.advanced(by: row * dbpr), pb.advanced(by: row * pbpr), run)
                }
            }
            IOSurfaceUnlock(prev, .readOnly, nil)
        }
        for part in apply {
            let r = part.intersection(whole)
            guard !r.isNull else { continue }
            let px = Int(r.minX), py = Int(r.minY)
            let pw = min(Int(r.width), w - px), ph = min(Int(r.height), h - py)
            guard pw > 0, ph > 0 else { continue }
            // Where the guest has drawn the desktop rather than a window, the
            // card marks it: absorbing it puts a hole through the picture.
            /*
             * Where the card says this patch is desktop rather than any
             * window, absorbing it puts a hole through the picture -- unless
             * the guest has just told us, in an answer that still describes
             * this screen, that this very region belongs to this window.  Then
             * the two disagree, and the guest is the one that knows: the
             * card's answer is a classification drawn from the shapes of
             * copies going past, and it gets windows wrong often enough that
             * the window being worked in could sit unreadable for tens of
             * seconds waiting for it to change its mind.
             */
            if regions != nil, !trustRegions,
               isDesktop(sb, sbpr, sw, sh, gx + px, gy + py, pw, ph) {
                gateDesktop += 1
                continue
            }
            for row in 0..<ph {
                let sy = gy + py + row, sx = gx + px
                guard sy >= 0, sy < sh, sx >= 0 else { continue }
                let run = max(0, min(pw, sw - sx)) * 4
                guard run > 0 else { continue }
                let dst = db.advanced(by: (py + row) * dbpr + px * 4)
                memcpy(dst, sb.advanced(by: sy * sbpr + sx * 4), run)
                /*
                 * Opaque, whatever the screen's own mask says.
                 *
                 * The alpha published with the guest's screen marks which
                 * parts of it are a window, so that in Harmony the desktop can
                 * be left out -- and it is carried along by this copy, which
                 * means a window whose tiles the card has misjudged is drawn
                 * see-through.  Measured: a window entirely correct in color,
                 * copied every frame, nought frames behind, and 81.5% of it
                 * invisible.  From the outside that is indistinguishable from
                 * a window that never updates, which is what it was reported
                 * as, repeatedly.
                 *
                 * This surface is already cropped to a rectangle the guest
                 * told us is a window.  Inside that rectangle the mask has
                 * nothing to add and everything to lose, so the copy asserts
                 * what is already known: these pixels belong to this window.
                 */
                var o = 3
                while o < run { dst.storeBytes(of: UInt8(0xff), toByteOffset: o, as: UInt8.self); o += 4 }
            }
            wrote = true
        }
        IOSurfaceUnlock(dst, [], nil)
        IOSurfaceUnlock(src, .readOnly, nil)
        guard wrote else { return c.lastGood ?? c.front }

        c.lastRegions = mine
        c.back = 1 - c.back
        let shown = c.surfaces[1 - c.back]
        c.lastGood = shown
        if regions == nil { cleanSnapshots.insert(id) }
        return shown
    }

    /// Whether the card says this patch is desktop rather than any window.  It
    /// stamps the alpha of everything it draws; the desktop comes out clear.
    private func isDesktop(_ base: UnsafeMutableRawPointer, _ bpr: Int, _ sw: Int, _ sh: Int,
                           _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        let pts = [(x + 1, y + 1), (x + w / 2, y + h / 2), (x + max(0, w - 2), y + max(0, h - 2))]
        for (px, py) in pts {
            guard px >= 0, py >= 0, px < sw, py < sh else { continue }
            let a = base.load(fromByteOffset: py * bpr + px * 4 + 3, as: UInt8.self)
            if a != 0 { return false }
        }
        return true
    }

    /// Start the pass that gives every window a clean copy of itself.
    func beginInitialCapture() {
        guard active, !stack.isEmpty else { return }
        captureQueue = stack.filter { proxies[$0.id] != nil }.map { $0.id }.reversed()
        captureRestore = stack.first(where: { proxies[$0.id] != nil })?.id
        captureTicks = 0; captureReady = false
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
        guard proxies[id] != nil else { captureQueue.removeFirst(); captureTicks = 0; captureReady = false; return }
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
                captureReady = true                 // fall through to the miss
            } else {
                captureTicks = 1
                return
            }
        }
        /*
         * The guest is slow: give it real time to paint before copying, or the
         * copy is of whatever was there before -- the desktop, usually.
         *
         * Counted in seconds, not in reports.  It was eighteen reports, with a
         * comment calling that a second and a half; the reports then went from
         * twelve a second to twenty-four and the same number quietly became
         * three quarters of a second, with nothing to say it had changed.
         */
        if !captureReady,
           Date().timeIntervalSince(captureBegan) < 0.9 { return }
        captureReady = true
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
        /*
         * Being in front is not the same as being uncovered.
         *
         * This pass used to copy on focus alone, and focus says only which
         * window the guest would send a keystroke to -- a menu pulled down
         * over it, a palette, a sheet, the Dock along the bottom edge, all
         * leave the window focused and none of them leave it readable.  What
         * it stores here is kept as that window's picture for good, so it is
         * held to exactly what an ordinary refresh is held to: the guest's
         * answer about what covers what has to be current, and it has to say
         * nothing covers this window.
         */
        let clear = occlusionIsCurrent && haveOcclusion && (occluded[id] ?? []).isEmpty
        if focusedGuestWindow == id, clear, let p = proxies[id] {
            _ = snapshot(id, p.guestRect, regions: nil)
            harmonyDebug("PECAP took \(id)")
        } else if focusedGuestWindow == id, !clear,
                  Date().timeIntervalSince(captureBegan) <= 4 {
            // In front but still covered by something: wait it out rather than
            // store a contaminated picture, up to the same deadline as a raise
            // that never takes.
            return
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
                captureTicks = 0; captureReady = false
                if captureQueue.count == 1 { finishCapture() }
                return
            }
        }
        captureQueue.removeFirst()
        captureTicks = 0; captureReady = false
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
        let cover = occluded[id] ?? []
        let rect = stack.first(where: { $0.id == id })?.rect ?? .zero
        let parts = rect.isEmpty ? [] : visibleParts(id, rect)
        let area = rect.width * rect.height
        let shown = parts.reduce(0) { $0 + $1.width * $1.height }
        let pct = area > 0 ? Int(shown / area * 100) : -1
        return "covers=\(cover.count) liveparts=\(parts.count) visible=\(pct)% "
            + "focus=\(focusedGuestWindow == id ? 1 : 0) fresh=\(fresh[id, default: -99]) "
            + "clean=\(cleanSnapshots.contains(id) ? 1 : 0)"
    }

    /// Write a window's own copy of itself to a PNG, to check by eye that the
    /// copies are right (POWEREMU_HARMONY_DEBUG only).
    func writeSnapshot(_ id: Int, to path: String) -> String {
        if let image = proxies[id]?.capturedImage {
            guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                "public.png" as CFString, 1, nil) else { return "could not write \(path)" }
            CGImageDestinationAddImage(dest, image, nil)
            return CGImageDestinationFinalize(dest) ? "wrote complete capture to \(path)" : "capture write failed"
        }
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

    /// A minimized guest window that no proxy is standing in for yet.
    private func unboundMinimized(for proxy: HarmonyProxy) -> (pid: Int, index: Int, title: String)? {
        let taken = Set(proxies.values.compactMap { p -> String? in
            guard let pid = p.minimizedPid else { return nil }
            return "\(pid)/\(p.minimizedIndex)"
        })
        let candidates = minimizedEntries.filter {
            let key = "\($0.pid)/\($0.index)"
            // Not already claimed, and not one that was already in the guest's
            // Dock before this window left the screen.
            return $0.pid == proxy.applicationPid && !taken.contains(key)
                && !(proxy.minimizedBaseline ?? []).contains(key)
        }
        return candidates.count == 1 ? candidates.first : nil
    }

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
        hostPointInMenuBar(NSEvent.mouseLocation)
    }

    func hostPointInMenuBar(_ point: CGPoint) -> Bool {
        guard screenFrame.height > 0 else { return false }
        return point.x >= screenFrame.minX && point.x < screenFrame.maxX &&
            point.y <= screenFrame.maxY && point.y > screenFrame.maxY - hostMenuBar
    }

    /// Taken out of this Mac's Dock: put the guest's window back too.
    func windowWillMiniaturize(_ n: Notification) {
        guard let p = n.object as? HarmonyProxy else { return }
        let wasRestoring = p.restoreIntent.isPending
        p.restoreIntent.cancelForMinimize()
        // Ours, from the vanished path: the guest window has already gone.
        guard p.minimizedPid == nil || wasRestoring else { return }
        // Record intent before the animation, and discard focus/click work
        // that must not reactivate this window while it enters the Dock.
        if pendingFocus?.id == p.id {
            focusTimeout?.cancel(); pendingFocus = nil; focusEvents = []
        }
        (p.contentView as? HarmonyProxyView)?.cancelPointerGesture()
        releaseInput?()
        p.minimizedBaseline = Set(minimizedEntries.map { "\($0.pid)/\($0.index)" })
        minimizing[p.id] = Date()
        settleAll(1.4)                    // the genie, which nothing can see
        harmonyDebug("PEMIN id=\(p.id) asked the guest")
        minimize?(p.id)
    }

    /// Called before native deminiaturization, including the Dock path. Keep
    /// restore intent and the guest binding until a visible WINDOWS report.
    func proxyWillRestore(_ p: HarmonyProxy) {
        guard p.minimizedPid != nil || minimizing[p.id] != nil || vanished[p.id] != nil || p.restoreIntent.isPending else { return }
        let sendRestore = p.restoreIntent.request(hasBinding: p.minimizedPid != nil)
        minimizing.removeValue(forKey: p.id)
        if sendRestore, let pid = p.minimizedPid {
            harmonyDebug("PEUNMIN id=\(p.id) pid=\(pid)/\(p.minimizedIndex) awaiting visibility")
            unminimize?(pid, p.minimizedIndex)
        }
    }

    func windowDidDeminiaturize(_ n: Notification) {
        guard let p = n.object as? HarmonyProxy else { return }
        // Idempotent fallback for native paths which bypass the override.
        proxyWillRestore(p)
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
    /*
     * Where the pointer is, told to the guest -- but no oftener than the guest
     * can care about.
     *
     * This Mac reports mouse movement upwards of a hundred times a second, and
     * every one of those was becoming a tablet report into an emulated machine
     * that has to be interrupted, scheduled and run to consume each one.  A
     * button press goes into the same queue, behind all of them, so a click
     * arrives only once the guest has waded through every stale position that
     * was posted while the hand was still moving -- and what the reader sees is
     * a window that takes seconds to notice a click that was delivered
     * promptly.  Positions are worth nothing once a newer one exists, so at
     * most one is sent per sixtieth of a second and the rest are dropped.
     *
     * A press is different: it is not worth anything late, and where it lands
     * depends on the position going with it.  So pressing sends the position
     * first, whatever the clock says.
     */
    private var pointSentAt = Date.distantPast
    private var pointSends = 0, pointDrops = 0
    private static let pointInterval: TimeInterval = 1.0 / 60.0

    func sendPointAtCursor(force: Bool = false) {
        guard screenFrame.width > 0, !cursorInHostMenuBar() else { return }
        let now = Date()
        if !force, now.timeIntervalSince(pointSentAt) < Self.pointInterval { pointDrops += 1; return }
        pointSentAt = now
        pointSends += 1
        let h = NSEvent.mouseLocation
        sendPointAtHostPoint(h)
    }
    func sendPointAtHostPoint(_ h: CGPoint) {
        if completeWindowCapture {
            let p = coordinates.guestPoint(h)
            withFocus { [weak self] in self?.sendPoint?(Int(p.x.rounded()), Int(p.y.rounded())) }
            return
        }
        let s = scale
        sendPoint?(Int((h.x - screenFrame.minX) / s),
                   Int(((screenFrame.maxY - h.y) - offsetY) / s))
    }
    func sendPointInProxy(_ id: Int, at host: CGPoint) {
        guard completeWindowCapture, let p = proxies[id] else { sendPointAtHostPoint(host); return }
        guard let view = p.contentView, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let position = view.convert(p.convertPoint(fromScreen: host), from: nil)
        let local = CGPoint(x: (position.x - view.bounds.minX) * p.guestRect.width / view.bounds.width,
                            y: (view.bounds.maxY - position.y) * p.guestRect.height / view.bounds.height)
        withFocus(windowID: id) { [weak self, weak p] in
            guard let self, let p, self.proxies[id] === p else { return }
            self.sendPoint?(Int((p.guestRect.minX + local.x).rounded()), Int((p.guestRect.minY + local.y).rounded()))
        }
    }
    func proxyButton(_ down: Bool, at point: CGPoint? = nil, windowID: Int? = nil) {
        if let point, let windowID { sendPointInProxy(windowID, at: point) }
        else if let point { sendPointAtHostPoint(point) } else { sendPointAtCursor(force: true) }
        if down { clicksSent += 1 }
        sendProxyButton(1, down, windowID: windowID)
    }
    /// Presses handed to the guest.  Nothing counted them, so "my click did
    /// nothing" could not be told from "my click never arrived".
    private var clicksSent = 0

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
        if completeWindowCapture {
            guard pendingFocus?.id != id else { return }
            focusSequence += 1
            let sequence = focusSequence
            pendingFocus = (id, sequence); focusEvents = []
            focusTimeout?.cancel()
            let timeout = DispatchWorkItem { [weak self] in self?.receiveFocus(id: id, sequence: sequence, ok: false) }
            focusTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
            requestFocus?(id, sequence)
            return
        }
        focusedGuestWindow = 0                  // nothing is copied until confirmed
        if hard { raiseWindowHard?(id) } else { raiseWindow?(id) }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let p = notification.object as? HarmonyProxy, p.occlusionState.contains(.visible) else { return }
        captureScheduler.invalidate(p.id)
        requestNextFrame()
    }

    func showFrontGuestWindow() {
        let id = proxies[focusedGuestWindow] != nil ? focusedGuestWindow :
            (order.first ?? proxies.values.filter { $0.isMiniaturized }.map { $0.id }.sorted().first)
        guard let id, let p = proxies[id] else { return }
        activateProxy(p)
    }

    func windowDidResignKey(_ notification: Notification) {
        menuFocus.cancel()
        if let p = notification.object as? HarmonyProxy {
            harmonyDebug("PEINPUT resignKey id=\(p.id) gesture=\((p.contentView as? HarmonyProxyView)?.hasPointerGesture == true) physicalButtons=\(NSEvent.pressedMouseButtons)")
            (p.contentView as? HarmonyProxyView)?.cancelPointerGesture()
        }
        if let p = notification.object as? HarmonyProxy, pendingFocus?.id == p.id {
            focusTimeout?.cancel(); pendingFocus = nil; focusEvents = []
        }
        releaseInput?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let proxy = notification.object as? HarmonyProxy, !proxy.isMenuBar else { return }
        proxyRaise(proxy.id)
    }

    func proxyRaise(_ id: Int) {
        guard !dragWindows.contains(id) else { return }
        if let child = modalChild(of: id) { activateProxy(child); return }
        guard minimizing[id] == nil, proxies[id]?.restoreIntent.isPending != true else { return }
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
        if id == focusedGuestWindow && pendingFocus == nil {
            proxies[id]?.orderFront(nil)
            return
        }
        // The guest raises it through the Accessibility API.  It used to be
        // done by faking a click on a patch of the window nothing covered,
        // which landed next to the reader's own click and read as a
        // double-click -- minimizing the window instead of raising it.
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
        /*
         * Undo the fold, so a window keeps the guest screen it came from.
         *
         * A window shown from the second guest screen was drawn here folded
         * back by a screen's width; converting a drag straight back would
         * hand the guest a coordinate on the *first* screen and quietly
         * migrate the window there.  Putting the fold back means dragging it
         * around this Mac moves it around its own guest screen, and leaving
         * Harmony finds it where the reader left it.
         */
        let fold = p.guestRect.minX - foldIntoPrimary(p.guestRect).minX
        requestGuestMove(id, to: CGPoint(x: gx + fold, y: gy))
    }

    /// Ask the guest to put a window's top-left at a guest point.
    /*
     * Keep the guest's window under the one being dragged.
     *
     * A drag moves this Mac's window and leaves the guest's where it was until
     * the button comes up.  For the window in hand that looks fine -- it is
     * still being read from the place the guest still has it -- but every
     * window it *uncovers* cannot be filled in, because in the guest it is
     * still covered, and the guest has no reason to redraw anything, so no
     * frames arrive at all.  Measured mid-drag: frames 0.0/s, copies 0/s,
     * windows four frames behind and climbing.  The two Macs disagree about
     * where the windows are, and nothing resolves it until the drag ends.
     *
     * So the guest is told as the drag goes, about ten times a second -- often
     * enough that the arrangements stay in step, rarely enough that setting a
     * window's position through Accessibility does not become the new
     * bottleneck.  The authoritative move still happens on release.
     */
    private var liveMoveAt = Date.distantPast
    func dragGuestAlong(_ id: Int, hostOrigin: CGPoint, height: CGFloat) {
        // A complete backing store stays valid while only its host window moves.
        guard !completeWindowCapture else { return }
        guard let p = proxies[id] else { return }
        let now = Date()
        guard now.timeIntervalSince(liveMoveAt) >= 0.1 else { return }
        liveMoveAt = now
        let sc = scale
        let target = CGPoint(x: (hostOrigin.x - screenFrame.minX) / sc,
                             y: ((screenFrame.maxY - (hostOrigin.y + height)) - offsetY) / sc)
        let from = p.guestRect.origin
        guard abs(from.x - target.x) >= 2 || abs(from.y - target.y) >= 2 else { return }
        moveWindowDrag?(id, Int(from.x.rounded()), Int(from.y.rounded()),
                        Int(target.x.rounded()), Int(target.y.rounded()))
    }

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
        settle(id, 0.75)                // it has been told to move; wait for it
        harmonyDebug(String(format: "PEMOVE id=%d %.0f,%.0f -> %.0f,%.0f",
                            id, from.x, from.y, target.x, target.y))
        if completeWindowCapture {
            moveWindow?(id, Int(target.x.rounded()), Int(target.y.rounded()))
            return
        }
        moveWindowDrag?(id, Int(from.x.rounded()), Int(from.y.rounded()),
                        Int(target.x.rounded()), Int(target.y.rounded()))
    }

}

/// One guest window as a borderless macOS window.
@MainActor
final class HarmonyProxy: NSWindow {
    var applicationPid: Int?
    var minimizedBaseline: Set<String>?
    var restoreIntent = HarmonyRestoreIntent()
    private(set) var capturedImage: CGImage?
    var acceptedCaptureSequence = 0
    let id: Int
    weak var manager: HarmonyWindowManager?
    var guestRect = CGRect.zero
    /// Where this window was dropped, until the guest reports it there.
    var pendingMove: CGPoint?
    var pendingSince = Date.distantPast
    private(set) var dragging = false
    /// The guest's menu bar strip, which owns clicks in the menu-bar band.
    var isMenuBar = false
    /// Set while this proxy is standing in for a minimized guest window.
    var minimizedPid: Int?
    var minimizedIndex = 0
    /// The window's own complete picture, taken while nothing covered it.
    private let tex = CALayer()
    /*
     * The guest's screen itself, cropped to this window and masked to the part
     * of it nothing is drawn over.  It sits on top of the complete picture, so
     * what can be read live is live and the rest falls back to the last good
     * copy -- rather than the whole window being one or the other.
     */
    private let liveTex = CALayer()
    private let liveMask = CAShapeLayer()

    init(id: Int, manager: HarmonyWindowManager) {
        self.id = id
        self.manager = manager
        /*
         * Titled rather than borderless, with the title bar made invisible and
         * the content filling the whole window.  It looks exactly the same, but
         * a borderless window cannot be put in the Dock -- miniaturize() simply
         * does nothing -- and a guest window that has been minimized needs to
         * go somewhere the reader can get it back from, now that the guest's
         * own Dock is hidden.
         */
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.titled, .miniaturizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        title = "Guest window \(id)"
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
        // Files can be dragged from this Mac straight onto a guest window.
        v.registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        v.wantsLayer = true
        v.layer = CALayer()
        v.layer?.cornerRadius = 6           // Aqua windows are rounded; the shadow follows this shape
        v.layer?.masksToBounds = true
        v.layer?.addSublayer(tex)
        v.layer?.addSublayer(liveTex)
        let still: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(),
                                         "position": NSNull(), "contentsRect": NSNull(),
                                         "path": NSNull(), "hidden": NSNull()]
        tex.contentsGravity = .resize
        tex.actions = still
        liveTex.contentsGravity = .resize
        liveTex.actions = still
        liveTex.mask = liveMask
        liveMask.actions = still
        liveMask.fillColor = NSColor.black.cgColor
        liveTex.isHidden = true
        contentView = v
        delegate = manager
    }

    var isDragImage = false {
        didSet { ignoresMouseEvents = isDragImage }
    }
    override var canBecomeKey: Bool { !isDragImage }
    override var canBecomeMain: Bool { !isDragImage }

    /// A proxy must sit exactly where the guest's window is, to the pixel.
    /// AppKit otherwise nudges windows back into the visible area -- down from
    /// under the menu bar, up from past the bottom -- which left the picture
    /// somewhere other than where the click arithmetic thought it was, so a
    /// click near the top landed above the pointer and one near the bottom
    /// below it, while the middle of the screen was exact.
    override func deminiaturize(_ sender: Any?) {
        manager?.proxyWillRestore(self)
        super.deminiaturize(sender)
    }

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

    /*
     * Show the guest's screen through this window, masked to `visible` (in this
     * window's own coordinates, top-left origin).  `crop` is where this window
     * sits in that screen, as a unit rectangle.
     */
    func setLive(_ screen: IOSurfaceRef, crop: CGRect, visible: [CGRect]) {
        guard !visible.isEmpty else { liveTex.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = contentView?.bounds ?? .zero
        liveTex.frame = b
        if (liveTex.contents as AnyObject?) !== (screen as AnyObject) { liveTex.contents = screen }
        liveTex.contentsRect = crop
        // The mask is in layer coordinates, which run from the bottom; the
        // guest's rectangles run from the top.
        let path = CGMutablePath()
        for r in visible {
            path.addRect(CGRect(x: r.minX, y: b.height - r.maxY, width: r.width, height: r.height))
        }
        liveMask.frame = b
        liveMask.path = path
        liveTex.isHidden = false
        CATransaction.commit()
    }

    func hideLive() {
        guard !liveTex.isHidden else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        liveTex.isHidden = true
        CATransaction.commit()
    }

    func setOwnSurface(_ s: IOSurfaceRef) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tex.contents = s
        tex.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        tex.frame = contentView?.bounds ?? .zero
        CATransaction.commit()
    }
    func setOwnImage(_ image: CGImage) {
        capturedImage = image
        CATransaction.begin(); CATransaction.setDisableActions(true)
        liveTex.isHidden = true
        tex.contents = image
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
final class HarmonyProxyView: NSView, NSDraggingSource {
    private weak var proxy: HarmonyProxy?
    private var dragOrigin: NSPoint?          // proxy origin at mouse-down (title-bar drag)
    private var dragMouse: NSPoint?           // screen mouse at mouse-down
    private var titleDownLocal: CGPoint?
    private var fileDragOrigin: CGPoint?
    private var fileDragPending = false
    private var fileDragGeneration = 0
    private var leftButtonForwarded = false
    private var dragMoved = false             // told apart on release: click or drag

    init(proxy: HarmonyProxy) { self.proxy = proxy; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The wheel belongs to whatever the pointer is over, like any other
    /// pointer event: put the guest's pointer there first, then turn the wheel.
    private var scrollCarry: CGFloat = 0
    private func hostPoint(_ e: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: e.locationInWindow) ?? e.locationInWindow
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: proxy?.manager?.guestCursor ?? .arrow)
    }
    override func mouseMoved(with e: NSEvent) {
        if let proxy { proxy.manager?.sendPointInProxy(proxy.id, at: hostPoint(e)) }
    }
    override func rightMouseDown(with e: NSEvent) {
        guard let proxy, let m = proxy.manager else { return }
        m.activateProxy(proxy); m.sendPointInProxy(proxy.id, at: hostPoint(e)); m.sendProxyButton(2, true, windowID: proxy.id)
    }
    override func rightMouseUp(with e: NSEvent) {
        if let proxy { proxy.manager?.sendPointInProxy(proxy.id, at: hostPoint(e)) }; proxy?.manager?.sendProxyButton(2, false, windowID: proxy?.id)
    }
    override func rightMouseDragged(with e: NSEvent) {
        if let proxy { proxy.manager?.sendPointInProxy(proxy.id, at: hostPoint(e)) }
    }
    override func scrollWheel(with e: NSEvent) {
        guard let proxy, let m = proxy.manager else { return }
        m.sendPointInProxy(proxy.id, at: hostPoint(e))
        // Trackpads give pixels; the guest counts wheel clicks.
        scrollCarry += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 12 : e.scrollingDeltaY
        let lines = Int32(scrollCarry.rounded(.towardZero))
        guard lines != 0 else { return }
        scrollCarry -= CGFloat(lines)
        m.sendProxyScroll(lines)
    }

    /*
     * A file dragged from this Mac and let go of over a guest window.  The
     * window is raised first, so what happens next happens in front of the
     * reader rather than behind whatever they dropped onto.
     */
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        s.draggingPasteboard.canReadObject(forClasses: [NSURL.self, NSFilePromiseReceiver.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let proxy, let m = proxy.manager else { return false }
        m.proxyRaise(proxy.id)
        if let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return m.dropFiles?(urls, proxy.id) ?? false
        }
        if let promises = s.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            return m.dropPromises?(promises, proxy.id) ?? false
        }
        return false
    }

    override func keyDown(with e: NSEvent) { proxy?.manager?.sendProxyKey(e) }
    override func keyUp(with e: NSEvent) { proxy?.manager?.sendProxyKey(e) }
    override func flagsChanged(with e: NSEvent) { proxy?.manager?.sendProxyKey(e) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        fileDragPending = false; fileDragOrigin = nil
    }

    var hasPointerGesture: Bool { leftButtonForwarded || dragOrigin != nil || fileDragPending }

    func cancelPointerGesture() {
        fileDragOrigin = nil; fileDragPending = false; fileDragGeneration += 1
        if dragMoved, let proxy { proxy.manager?.moveProxyToGuest(proxy.id, origin: proxy.frame.origin) }
        if dragOrigin != nil { proxy?.manager?.suspendPointerTracking = false }
        dragOrigin = nil; dragMouse = nil; titleDownLocal = nil; dragMoved = false
        leftButtonForwarded = false
    }

    override func mouseDown(with e: NSEvent) {
        guard let proxy, let m = proxy.manager else { return }
        if dragOrigin != nil || leftButtonForwarded { cancelPointerGesture(); m.releaseInput?() }
        if !proxy.isMenuBar && m.hostPointInMenuBar(hostPoint(e)) { return }   // that band is this Mac's
        m.logClick(proxy)
        harmonyDebug("PEEVENT id=\(proxy.id) event=\(e.locationInWindow) local=\(convert(e.locationInWindow, from: nil)) bounds=\(bounds) host=\(hostPoint(e))")
        if proxy.isMenuBar {                          // the guest's menu bar: pass the click on
            leftButtonForwarded = true
            m.sendPointInProxy(proxy.id, at: hostPoint(e)); m.proxyButton(true, at: hostPoint(e), windowID: proxy.id)
            return
        }
        if m.redirectBlockedInteraction(proxy.id) { return }
        m.activateProxy(proxy)                       // select the host window and focus its guest
        let p = convert(e.locationInWindow, from: nil)
        if p.y >= bounds.height - 22 && !m.isSheetWindow(proxy.id) {
            /*
             * The title bar carries the close, minimize and zoom buttons as
             * well as being the handle to drag by, and which one a press means
             * is not known until it is let go of: a press that never moves is a
             * click for the guest, a press that moves is a drag of the window.
             * Sending the press straight through would have the guest drag its
             * own window as well as the proxy moving.
             */
            titleDownLocal = p
            dragOrigin = proxy.frame.origin
            dragMouse = hostPoint(e)
            dragMoved = false
            m.suspendPointerTracking = true
        } else {                                      // content: the click is the guest's
            fileDragOrigin = m.finderWindows.contains(proxy.id) ? hostPoint(e) : nil
            fileDragGeneration += 1
            if fileDragOrigin != nil { m.armDrag(proxy.id, at: hostPoint(e)) }
            leftButtonForwarded = true
            m.sendPointInProxy(proxy.id, at: hostPoint(e)); m.proxyButton(true, at: hostPoint(e), windowID: proxy.id)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let proxy, let m = proxy.manager else { return }
        if m.redirectBlockedInteraction(proxy.id) { cancelPointerGesture(); return }
        if fileDragPending { return }
        if let origin = fileDragOrigin, !bounds.contains(convert(e.locationInWindow, from: nil)), !m.pointerOverGuestWindow(hostPoint(e)) {
            // Preserve ordinary Finder drags inside the guest. Crossing the
            // window edge hands the drag to AppKit's native file promises.
            fileDragPending = true; leftButtonForwarded = false
            let generation = fileDragGeneration
            m.beginFileDrag(proxy.id) { [weak self, weak m, weak proxy] items in
                // A late reply belongs to the old gesture. It must never release
                // a newer mouse press or clear the newer drag's state.
                guard let self, self.fileDragGeneration == generation else { return }
                if let proxy { m?.proxyButton(false, at: origin, windowID: proxy.id) }
                guard NSEvent.pressedMouseButtons & 1 != 0, !items.isEmpty else {
                    self.fileDragPending = false; self.fileDragOrigin = nil; return
                }
                let point = self.convert(self.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? e.locationInWindow, from: nil)
                for (i, item) in items.enumerated() { item.setDraggingFrame(NSRect(x: point.x + CGFloat(i % 4) * 3, y: point.y, width: 40, height: 40), contents: item.imageComponents?.first?.contents) }
                self.beginDraggingSession(with: items, event: e, source: self)
            }
            return
        }
        if let o = dragOrigin, let dm = dragMouse {
            let now = hostPoint(e)
            if !dragMoved, abs(now.x - dm.x) < 3, abs(now.y - dm.y) < 3 { return }  // still a click
            if !dragMoved { dragMoved = true; proxy.beginDrag() }
            let where_ = NSPoint(x: o.x + (now.x - dm.x), y: o.y + (now.y - dm.y))
            proxy.setFrameOrigin(where_)
            // and bring the guest's own window with it, so the two Macs agree
            // about what covers what while the drag is still happening.
            m.dragGuestAlong(proxy.id, hostOrigin: where_, height: proxy.frame.height)
        } else {
            m.sendPointInProxy(proxy.id, at: hostPoint(e))
        }
    }

    override func mouseUp(with e: NSEvent) {
        if fileDragPending, let proxy { proxy.manager?.proxyButton(false, at: fileDragOrigin, windowID: proxy.id) }
        fileDragOrigin = nil; fileDragPending = false; fileDragGeneration += 1
        guard let proxy, let m = proxy.manager else { return }
        if m.redirectBlockedInteraction(proxy.id) { cancelPointerGesture(); return }
        if dragOrigin != nil {
            if dragMoved {                            // a drag: put the guest's window where it landed
                m.moveProxyToGuest(proxy.id, origin: proxy.frame.origin)
            } else {                                  // a click: the guest's to handle, buttons and all
                m.suspendPointerTracking = false
                let local = convert(e.locationInWindow, from: nil)
                guard let down = dragMouse, let downLocal = titleDownLocal,
                      HarmonyTitleClick.accepts(downScreen: down, upScreen: hostPoint(e),
                                                downLocal: downLocal, upLocal: local, height: bounds.height) else {
                    cancelPointerGesture(); return
                }
                if local.x >= 25 && local.x <= 47 && local.y >= bounds.height - 22 {
                    // Minimize the native window first. Its delegate asks the
                    // guest to minimize and binds the resulting Dock entry.
                    proxy.performMiniaturize(nil)
                    dragOrigin = nil; dragMouse = nil; titleDownLocal = nil; dragMoved = false
                    return
                }
                m.sendPointInProxy(proxy.id, at: hostPoint(e))
                m.proxyButton(true, at: hostPoint(e), windowID: proxy.id)
                m.proxyButton(false, at: hostPoint(e), windowID: proxy.id)
            }
            dragOrigin = nil; dragMouse = nil; titleDownLocal = nil; dragMoved = false
            m.suspendPointerTracking = false
        } else if leftButtonForwarded {
            leftButtonForwarded = false
            m.sendPointInProxy(proxy.id, at: hostPoint(e)); m.proxyButton(false, at: hostPoint(e), windowID: proxy.id)
        }
    }

}
