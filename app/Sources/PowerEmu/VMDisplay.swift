import AppKit
import IOSurface
import QuartzCore

/// The virtual Mac's screen inside PowerEmu (instead of QEMU's own window).
///
/// QEMU's poweremu-display object (poweremu-qemu: ui/poweremu-display.c)
/// connects to a Unix socket PowerEmu listens on.  It passes the guest's
/// screen as shared memory (its fd with SCM_RIGHTS) and then only says which
/// rectangle changed; PowerEmu accumulates damage in staging IOSurfaces and
/// publishes an immutable copy to Core Animation.  Keyboard and mouse go back
/// the same way.  Messages: { u32 type, u32 length } + payload; see the QEMU
/// file for the list.
final class DisplayChannel: @unchecked Sendable {
    enum Kind: UInt32 { case surface = 1, damage = 2, cursor = 3, mouse = 4, key = 10, motion = 11, buttons = 12, wheel = 13, point = 14, harmony = 15 }

    let socketPath: String
    /// Called on the main thread.
    /// The frame, and the part of it the guest has just drawn (nil = all of it).
    var onFrame: ((IOSurfaceRef, Int, Int, CGRect) -> Void)?
    var onCursor: ((CGImage?, Int, Int) -> Void)?          // image, hot spot
    var onMouse: ((Int, Int, Bool) -> Void)?
    var onDisconnect: (() -> Void)?
    /// Harmony: the guest's windows (id + rectangle), from the agent (not the
    /// socket); the view sets this and the machine forwards the report here.
    var onWindows: (([(id: Int, rect: CGRect, visible: CGRect)]) -> Void)?
    func deliverWindows(_ w: [(id: Int, rect: CGRect, visible: CGRect)]) { onWindows?(w) }
    var onWindowApps: (([(id: Int, pid: Int, app: String)]) -> Void)?
    func deliverWindowApps(_ a: [(id: Int, pid: Int, app: String)]) { onWindowApps?(a) }
    var onMinimized: (([(pid: Int, index: Int, title: String)]) -> Void)?
    func deliverMinimized(_ m: [(pid: Int, index: Int, title: String)]) { onMinimized?(m) }
    /// What is in the guest's own Dock, which Harmony hides.
    var onDockApps: (([(path: String, name: String, pid: Int)]) -> Void)?
    func deliverDockApps(_ a: [(path: String, name: String, pid: Int)]) { onDockApps?(a) }
    /// Harmony: the front guest application's menu bar, and the contents of
    /// one of its menus once it has been asked for.
    var onFocused: ((Int) -> Void)?
    func deliverFocused(_ id: Int) { onFocused?(id) }
    var onOcclusion: (([Int: [CGRect]]) -> Void)?
    func deliverOcclusion(_ o: [Int: [CGRect]]) { onOcclusion?(o) }
    var onAppIcon: ((Int, Data) -> Void)?
    var onWindowFrame: ((Data) -> Void)?
    var onFocusReady: ((Int, Int, Bool) -> Void)?
    var onSheets: (([Int: Int]) -> Void)?
    var onDragWindows: ((Set<Int>) -> Void)?
    var onMenuFocus: ((String, Int) -> Void)?
    var onGuestFullscreen: (() -> Void)?
    var onHarmonyReady: ((String, CGSize, Bool) -> Void)?
    func deliverAppIcon(_ pid: Int, _ png: Data) { onAppIcon?(pid, png) }
    var onMenuBar: ((Int, String, [(index: Int, title: String)]) -> Void)?
    func deliverMenuBar(_ pid: Int, _ app: String, _ t: [(index: Int, title: String)]) { onMenuBar?(pid, app, t) }
    var onMenuItems: ((Int, String, [HarmonyMenuItem]) -> Void)?
    func deliverMenuItems(_ pid: Int, _ path: String, _ i: [HarmonyMenuItem]) { onMenuItems?(pid, path, i) }
    /// Sends a verb back to the guest agent (set by the machine).
    var sendToAgent: ((String, String) -> Void)?

    private var listenFD: Int32 = -1
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    /// Harmony mode: the emulator hands over frames whose desktop is
    /// transparent.  Kept here so it can be asked for again after a
    /// reconnection, which otherwise starts the emulator off opaque.
    private(set) var harmony = false

    // The shared frame from QEMU and our two copies of it.
    private var shm: UnsafeMutableRawPointer?
    private var shmSize = 0
    private var width = 0, height = 0, stride = 0
    private var surfaces: [IOSurfaceRef] = []
    private var back = 0
    /// Per surface, what has been drawn since it was last written.
    private var dirty: [CGRect] = [.null, .null]
    private let pendingLock = NSLock()
    private var pending = false            // a frame is waiting for the main thread
    private var surfaceGeneration: UInt64 = 0
    /*
     * What has been drawn into the frame that is waiting.
     *
     * Frames can be merged: while the main thread has not shown the last one,
     * later updates are copied into that same surface.  The damage handed to
     * the main thread used to be whichever rectangle arrived first, so the
     * picture contained changes the report did not mention -- harmless while
     * whole windows are copied and wrong the moment only the damaged part is.
     */
    private var pendingDrawn: CGRect = .null
    /*
     * Which frame this is, counted from the first.  Everything downstream can
     * then say which frame it acted on, and "the host was offered twenty-five
     * frames a second" can be told apart from "the window it is showing has
     * not moved on in ninety seconds" -- which is exactly the pair that was
     * confused all day.
     */
    private(set) var frameSeq = 0
    /// Frames put on screen since the start (for the overlay).
    private(set) var framesShown = 0

    init(socketPath: String) { self.socketPath = socketPath }

    func start() throws {
        unlink(socketPath)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { b in for (i, x) in bytes.enumerated() { b[i] = x } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(s, 1) == 0 else { close(s); throw POSIXError(.EADDRINUSE) }
        listenFD = s
        let t = Thread { [weak self] in self?.run() }
        t.name = "PowerEmu display"
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() {
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        unlink(socketPath)
    }

    // MARK: input to QEMU

    func setHarmony(_ on: Bool) {
        harmony = on
        send(.harmony, [on ? 1 : 0])
    }

    func send(_ kind: Kind, _ values: [Int32]) {
        var msg = [UInt32(kind.rawValue), UInt32(values.count * 4)]
        msg += values.map { UInt32(bitPattern: $0) }
        writeLock.lock(); defer { writeLock.unlock() }
        guard fd >= 0 else { return }
        msg.withUnsafeBytes { raw in
            var p = raw.baseAddress!, left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                p += n; left -= n
            }
        }
    }

    // MARK: reading

    private func run() {
        let c = accept(listenFD, nil, nil)
        close(listenFD); listenFD = -1
        guard c >= 0 else { return }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        writeLock.lock(); fd = c; writeLock.unlock()
        if harmony { send(.harmony, [1]) }

        var buf = Data()
        var fds: [Int32] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var control = [UInt8](repeating: 0, count: 64)
        while true {
            var iov = iovec()
            var msg = msghdr()
            let n: Int = chunk.withUnsafeMutableBytes { cb in
                control.withUnsafeMutableBytes { ctl in
                    iov.iov_base = cb.baseAddress; iov.iov_len = cb.count
                    return withUnsafeMutablePointer(to: &iov) { iovp in
                        msg.msg_iov = iovp; msg.msg_iovlen = 1
                        msg.msg_control = ctl.baseAddress; msg.msg_controllen = socklen_t(ctl.count)
                        let r = recvmsg(c, &msg, 0)
                        // Collect any descriptor that came with these bytes.
                        if r > 0, msg.msg_controllen >= MemoryLayout<cmsghdr>.size {
                            let h = ctl.baseAddress!.assumingMemoryBound(to: cmsghdr.self).pointee
                            if h.cmsg_level == SOL_SOCKET && h.cmsg_type == SCM_RIGHTS {
                                let fdPtr = ctl.baseAddress!.advanced(by: MemoryLayout<cmsghdr>.size)
                                fds.append(fdPtr.assumingMemoryBound(to: Int32.self).pointee)
                            }
                        }
                        return r
                    }
                }
            }
            if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
            buf.append(contentsOf: chunk[0..<n])
            while buf.count >= 8 {
                let type = buf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                let len = Int(buf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
                guard buf.count >= 8 + len else { break }
                let payload = Data(buf[buf.startIndex + 8 ..< buf.startIndex + 8 + len])
                buf = Data(buf[(buf.startIndex + 8 + len)...])
                handle(type, payload, &fds)
            }
        }
        writeLock.lock(); close(c); fd = -1; writeLock.unlock()
        DispatchQueue.main.async { self.onDisconnect?() }
    }

    private func u32(_ d: Data, _ i: Int) -> Int { Int(d.withUnsafeBytes { $0.load(fromByteOffset: i * 4, as: UInt32.self) }) }
    private func i32(_ d: Data, _ i: Int) -> Int { Int(d.withUnsafeBytes { $0.load(fromByteOffset: i * 4, as: Int32.self) }) }

    private func handle(_ type: UInt32, _ p: Data, _ fds: inout [Int32]) {
        switch Kind(rawValue: type) {
        case .surface:
            guard p.count >= 12, !fds.isEmpty else { return }
            let f = fds.removeFirst()
            newSurface(fd: f, width: u32(p, 0), height: u32(p, 1), stride: u32(p, 2))
            close(f)
        case .damage:
            // The guest says which part of its screen it drew.  This used to be
            // thrown away and the whole 7 MB frame copied regardless.
            if p.count >= 16 {
                present(CGRect(x: u32(p, 0), y: u32(p, 1), width: u32(p, 2), height: u32(p, 3)))
            } else {
                present(nil)
            }
        case .cursor:
            guard p.count >= 16 else { return }
            let w = u32(p, 0), h = u32(p, 1), hx = u32(p, 2), hy = u32(p, 3)
            guard w > 0, h > 0, p.count >= 16 + w * h * 4 else { return }
            let pixels = p.subdata(in: 16 ..< 16 + w * h * 4) as CFData
            let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: CGDataProvider(data: pixels)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            DispatchQueue.main.async { self.onCursor?(image, hx, hy) }
        case .mouse:
            guard p.count >= 12 else { return }
            let x = i32(p, 0), y = i32(p, 1), on = i32(p, 2) != 0
            DispatchQueue.main.async { self.onMouse?(x, y, on) }
        default:
            break
        }
    }

    private func newSurface(fd f: Int32, width w: Int, height h: Int, stride s: Int) {
        if let shm { munmap(shm, shmSize) }
        let page = Int(getpagesize())
        shmSize = (s * h + page - 1) / page * page
        guard let m = mmap(nil, shmSize, PROT_READ, MAP_SHARED, f, 0), m != MAP_FAILED else { shm = nil; return }
        shm = m; width = w; height = h; stride = s
        let bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4)
        let props: [CFString: Any] = [kIOSurfaceWidth: w, kIOSurfaceHeight: h, kIOSurfaceBytesPerElement: 4,
                                      kIOSurfaceBytesPerRow: bpr, kIOSurfacePixelFormat: 0x42475241 /* 'BGRA' */]
        pendingLock.lock()
        surfaceGeneration &+= 1
        pending = false
        pendingDrawn = .null
        surfaces = (0..<2).compactMap { _ in IOSurfaceCreate(props as CFDictionary) }
        back = 0
        dirty = [.null, .null]
        pendingLock.unlock()
        present(nil)
    }

    /// Copy what the guest has drawn into the back surface and show it.  While
    /// the main thread hasn't shown the last one yet, keep refreshing that one.
    ///
    /// Only the damaged part is copied.  The two surfaces are written in turn,
    /// so each one has to be brought up to date with everything drawn since it
    /// was last written, not merely since the last frame -- otherwise they
    /// drift apart and the picture alternates between two different moments.
    private func present(_ damage: CGRect?) {
        guard let shm, surfaces.count == 2 else { return }
        let all = CGRect(x: 0, y: 0, width: width, height: height)
        pendingLock.lock()
        let target = pending ? 1 - back : back
        for i in 0..<2 {
            dirty[i] = dirty[i].isNull ? (damage ?? all) : dirty[i].union(damage ?? all)
        }
        let area = dirty[target].intersection(all)
        dirty[target] = .null
        let s = surfaces[target]
        if !area.isNull, area.width >= 1, area.height >= 1 {
            IOSurfaceLock(s, [], nil)
            let dst = IOSurfaceGetBaseAddress(s), bpr = IOSurfaceGetBytesPerRow(s)
            let x0 = max(0, Int(area.minX)), y0 = max(0, Int(area.minY))
            let x1 = min(width, Int(area.maxX)), y1 = min(height, Int(area.maxY))
            let run = max(0, x1 - x0) * 4
            if run > 0 {
                for y in y0..<max(y0, y1) {
                    memcpy(dst + y * bpr + x0 * 4, shm + y * stride + x0 * 4, run)
                }
            }
            IOSurfaceUnlock(s, [], nil)
        }
        let first = !pending
        let generation = surfaceGeneration
        let mine = damage ?? all
        pendingDrawn = pendingDrawn.isNull ? mine : pendingDrawn.union(mine)
        if first { pending = true; back = 1 - back }
        pendingLock.unlock()
        guard first else { return }
        let w = width, h = height
        DispatchQueue.main.async {
            self.pendingLock.lock()
            guard generation == self.surfaceGeneration else {
                self.pendingLock.unlock()
                return
            }
            // The pair above is staging storage, not display storage. Reusing
            // it after onFrame returns races Core Animation's asynchronous
            // reader. Seal a frame under the producer lock and never mutate
            // the published surface again.
            let published = HarmonySurfaceSnapshot.copy(s)
            self.pending = false
            let drawn = self.pendingDrawn.isNull ? all : self.pendingDrawn
            self.pendingDrawn = .null
            self.pendingLock.unlock()
            guard let published else { return }
            self.framesShown += 1
            self.frameSeq += 1
            self.onFrame?(published, w, h, drawn)
        }
    }
}

/// What the window says while there is nothing to show.
///
/// Waking reads the machine's memory back before a single frame arrives,
/// and going to sleep writes it out with the picture frozen.  Both take
/// tens of seconds on a large machine, and without a word a black window
/// reads as a virtual Mac that has failed to start.
final class VMStatusView: NSView {
    private let wheel = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Dark enough to read against, but not opaque: going to sleep, the
        // last thing the virtual Mac drew stays faintly behind it.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        wheel.style = .spinning
        wheel.controlSize = .regular
        wheel.isIndeterminate = true
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = .white
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor.white.withAlphaComponent(0.7)
        detail.alignment = .center
        let stack = NSStackView(views: [wheel, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, _ note: String?, spinning: Bool = true) {
        title.stringValue = text
        detail.stringValue = note ?? ""
        detail.isHidden = note == nil
        isHidden = false
        /*
         * A failure is not a progress report.  The spinner used to keep
         * turning under "Harmony could not match the display", which reads
         * as still trying when nothing is happening at all.
         */
        wheel.isHidden = !spinning
        if spinning {
            wheel.startAnimation(nil)
        } else {
            wheel.stopAnimation(nil)
        }
    }

    func hideStatus() {
        guard !isHidden else { return }
        wheel.stopAnimation(nil)
        isHidden = true
    }

    /// Never in the way: the toolbar above it and the guest below it go on
    /// receiving what the reader does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shows the frames, draws the guest's hardware cursor, and turns keyboard
/// and mouse events into input for the guest.
final class VMDisplayView: NSView {
    let channel: DisplayChannel
    var onToggleFullScreen: (() -> Void)?
    /// So the window can say, in its title, that a feature still being
    /// tested is switched on.
    var onHarmonyChanged: ((Bool) -> Void)?
    /// And so the guest can be asked to put its Dock and desktop away.
    var onHarmonyGuest: ((Bool) -> Void)?
    /// Harmony wants the guest at this Mac's screen resolution so its windows
    /// land 1:1; (0,0) means put the guest's normal resolution back.
    var onHarmonyResolution: ((Int, Int) -> Void)?
    /// Rootless Harmony: raise a guest window (id), or move it (id, x, y top-left).
    var onHarmonyRaise: ((Int) -> Void)?
    var onHarmonyRaiseHard: ((Int) -> Void)?
    /// Ask the guest for one of its applications' icons, and quit one.
    var onWantAppIcon: ((Int) -> Void)?
    /// Files dragged from this Mac onto one of the guest's windows.
    var onArmFileDrag: ((Int, CGPoint) -> Void)?
    var onPrepareFileDrag: ((Int, @escaping ([NSDraggingItem]) -> Void) -> Void)?
    var onDropFilesToApp: (([URL], Int) -> Bool)?
    var onDropPromises: (([NSFilePromiseReceiver], Int) -> Bool)?
    var onDropFiles: (([URL], Int) -> Bool)?
    var onQuitGuestApp: ((Int) -> Void)?
    var onHarmonyMove: ((Int, Int, Int) -> Void)?
    var onHarmonyRaiseAt: ((Int, Int, Int) -> Void)?
    var onHarmonyMoveDrag: ((Int, Int, Int, Int, Int) -> Void)?
    /// The control bar floating over the top of the screen.
    weak var controls: VMToolbarController?
    private let screen = CALayer()
    private let cursor = CALayer()
    private let hint = CATextLayer()
    private let perf = PerfHUD()
    private let status = VMStatusView()
    /// Whether the message goes away by itself once the guest draws.
    private var statusUntilFrame = false
    private var fpsHistory = PerfHistory()
    private var windowHistory = PerfHistory()
    private var emuHistory = PerfHistory()
    private var cpuPerformance = CPUPerformance()
    private var cpuHistories: [Int: PerfHistory] = [:]
    private var drawHistory = PerfHistory()
    /// Where the reader dragged the overlay, as a fraction of the view.
    private var perfSpot: CGPoint?
    /// The last sampled overlay contents, so the pointer line can be redrawn
    /// between samples without re-measuring everything.
    private var hudRows: [PerfHUD.Row] = []
    private var hudLines: [String] = []
    /// Harmony: the overlay's own window, above the guest's proxy windows.
    private var hudWindow: NSWindow?
    private var hudTicker: Timer?
    private var debugTimer: Timer?

    /*
     * The guest does not put its pointer where an absolute point is sent.  Its
     * tablet area is larger than its screen, so what arrives is the point
     * scaled about the middle of the screen -- measured here at 1.178x, steady
     * to within a pixel.  It has always been so; it simply never showed,
     * because in seamless mode the guest draws its own pointer and you aim with
     * that.  Harmony hides it and you aim with this Mac's, so the error
     * becomes the whole story.
     *
     * Rather than carry a magic number, watch where the guest actually puts its
     * pointer against where it was sent, fit guest = k*sent + b per axis, and
     * send the inverse.  Self-correcting, and right again after a mode change.
     */
    private struct PointerFit {
        var n = 0.0, ss = 0.0, sg = 0.0, sss = 0.0, ssg = 0.0
        mutating func add(_ s: Double, _ g: Double) {
            n += 1; ss += s; sg += g; sss += s * s; ssg += s * g
        }
        /// (scale, offset), once there is enough spread to mean anything.
        var solved: (k: Double, b: Double)? {
            guard n >= 6 else { return nil }
            let den = n * sss - ss * ss
            guard den > 1e6 else { return nil }          // all samples bunched together
            let k = (n * ssg - ss * sg) / den
            guard k > 0.5, k < 2 else { return nil }     // nonsense: leave it alone
            return (k, (sg - k * ss) / n)
        }
        mutating func reset() { self = PointerFit() }
    }
    private var fitX = PointerFit(), fitY = PointerFit()
    /// Calibrating on the way in: a handful of points across the guest's
    /// screen, so the correction is right from the first click instead of
    /// waiting for the pointer to wander far enough to work it out.
    private var probePoints: [CGPoint] = []
    private var probeAt = 0
    private var probeTicks = 0
    private var probeSettled = CGPoint(x: -1, y: -1)
    private var lastRawSent: CGPoint?
    private var lastSettleHost = CGPoint(x: -9e9, y: -9e9)
    private var lastSettleGuest = CGPoint(x: -9e9, y: -9e9)
    /// What the correction is doing, for the overlay.
    private(set) var pointerFitText = "measuring"
    private var perfDragFrom: CGPoint?
    private var perfTimer: Timer?
    private var lastPerf: (time: TimeInterval, frames: Double, draws: Double, shown: Int,
                           texVRAM: Double, texAGP: Double, agpBytes: Double)?
    /// Asks the GPU model for its totals ("frames=… draws=…").
    var queryPerf: ((@escaping @Sendable (String?) -> Void) -> Void)?
    /// The emulator's pid, for the overlay's host-side figures.
    var qemuPID: (() -> pid_t?)?
    private let hostStats = HostStats()
    var showsPerformance: Bool { perfTimer != nil }
    private(set) var guestSize = CGSize(width: 1024, height: 768) {
        // Scanlines and the phosphor mask are sized from the guest's screen,
        // so a resolution change has to rebuild the filter.
        didSet { if guestSize != oldValue, panelFilter > 0 { applyPanelFilter() } }
    }
    private var cursorHot = CGPoint.zero
    private var cursorPos = CGPoint.zero
    private var cursorSize = CGSize.zero
    private var cursorOn = false
    private(set) var grabbed = false
    private var buttons: Int32 = 0
    private var pressed = Set<UInt16>()
    private var synthesized = Set<UInt16>()          // modifiers pressed on an event's behalf
    private var motion = CGPoint.zero                 // fractions not yet sent
    private var scroll: CGFloat = 0

    /// Harmony click-through: the most recent guest frame -- to read whether
    /// the pixel under the pointer is one of the guest's windows (opaque) or
    /// its see-through desktop -- and the pointer monitors that, while harmony
    /// is on, let a click on the desktop reach this Mac behind the guest.
    private var lastSurface: IOSurfaceRef?

    /*
     * Phase 2: the masked desktop.
     *
     * Instead of rebuilding each guest window as its own host window from
     * crops of the finished guest screen, show that screen once, whole, and
     * let the window mask decide what of it is drawn.  The guest composites
     * its own windows, as it always did; nothing here has to work out what
     * covers what, hold a clean copy of anything, raise a window to read it,
     * or reconcile two machines' ideas of where things are.  Everything the
     * reader sees comes from one scene. Window geometry still arrives on a
     * separate channel, so transient mask/frame disagreement remains possible.
     * Independent windows require complete backing-store captures instead.
     *
     * What is given up: the guest's windows are one stacking group.  A native
     * Mac window can sit in front of all of them or behind all of them, not
     * between two.  That is not Coherence, and it should not be described as
     * it. The complete-window capture experiment removes that restriction.
     *
     * Legacy fallback, selected with POWEREMU_HARMONY_MASKED=1.
     */
    // Independent complete-window capture is the Harmony test build's default.
    // Its content refresh budget remains an explicit performance limitation.
    let maskedDesktop = ProcessInfo.processInfo.environment["POWEREMU_HARMONY_MASKED"] == "1"
    /// What the mouse mode was before the masked desktop borrowed it.
    private var preMaskedMouseMode: MouseMode?

    // Click routing uses the same layer-local path as rendering. Do not use
    // the GPU's coarse tile alpha or the full view bounds for this decision.
    private var harmonyPointerMonitors: [Any] = []
    private var passingThrough = false
    private var clickThroughTimer: Timer?
    /// The window's size and frame before Harmony grew it to cover the screen.
    private var preHarmonyFrame: NSRect?
    private var preHarmonyStyle: NSWindow.StyleMask?
    private var preHarmonyLevel: NSWindow.Level?
    private var preHarmonyGuestSize: CGSize?          // the guest mode to restore on exit

    /// Harmony mode: each of the guest's windows is drawn as its own layer on
    /// this Mac's desktop -- so they stack independently and, being their own
    /// pieces, move without the whole-screen mask's tearing -- and its own
    /// desktop is simply not drawn.
    /// Quitting with Harmony still on used to leave the guest in Harmony's
    /// resolution, which it then remembered and booted into -- a mode its
    /// firmware does not draw correctly, so the gray Apple came up sheared.
    /// Put the guest's own resolution back before going.
    /// Take this machine's guest Dock tiles down.  Used on the way out of the
    /// app, where nothing else would: the helpers are children of PowerEmu and
    /// this Mac does not end them with it.
    func stopGuestDock() {
        guestDock.stop()
        closeGuestAppsPanel()
    }

    func restoreGuestResolutionIfNeeded() {
        guard harmony, let s = preHarmonyGuestSize else { return }
        onHarmonyResolution?(Int(s.width), Int(s.height))
        preHarmonyGuestSize = nil
    }

    /// Turn Harmony on or off.  In a full-screen space there is nothing behind
    /// the guest to harmonize with -- no desktop, no other apps -- so leave
    /// full screen first and turn it on once the space has gone.
    private var harmonyPreparation: (token: String, target: CGSize, acknowledged: Bool)?
    var isHarmonyDisplayTransition: Bool { harmony || harmonyPreparation != nil }
    private var harmonyPreparationTimeout: DispatchWorkItem?

    func requestHarmony(_ on: Bool) {
        if !on {
            harmonyPreparation = nil
            harmonyPreparationTimeout?.cancel()
            if !harmony, let original = preHarmonyGuestSize {
                onHarmonyResolution?(Int(original.width), Int(original.height))
                preHarmonyGuestSize = nil
            }
            harmony = false
            clearStatus()
            return
        }
        guard !harmony, harmonyPreparation == nil else { return }
        if let w = window, w.styleMask.contains(.fullScreen) {
            w.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.window?.styleMask.contains(.fullScreen) == false else { return }
                self.requestHarmony(true)
            }
            return
        }
        guard let host = window?.screen ?? NSScreen.main else { return }
        let target = HarmonyDisplayMode.size(screen: host)
        preHarmonyGuestSize = guestSize
        let token = UUID().uuidString
        harmonyPreparation = (token, target, false)
        showStatus("Preparing Harmony…", "Matching the guest display to this Mac.")
        channel.sendToAgent?("PREPAREHARMONY", "\(token) \(Int(target.width)) \(Int(target.height))")
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.harmonyPreparation?.token == token else { return }
            /*
             * Say which half failed.  "Could not match the display" with
             * advice to install the tools is right when the agent never
             * answered, and misleading when it answered and the guest
             * simply settled at a size that is not the one asked for --
             * which is what happens when the window has moved to another
             * screen, or the guest has no mode of exactly this size.
             */
            let got = self.guestSize
            let want = self.harmonyPreparation?.target ?? .zero
            let acked = self.harmonyPreparation?.acknowledged ?? false
            self.requestHarmony(false)
            if acked {
                self.showStatus("Harmony could not match the display",
                                "The virtual Mac went to \(Int(got.width))x\(Int(got.height)), "
                                + "not \(Int(want.width))x\(Int(want.height)). "
                                + "Try again with the window on the display you want to match.",
                                spinning: false, dismissAfter: 12)
            } else {
                self.showStatus("Harmony could not match the display",
                                "Install PowerEmu Tools \(GuestTools.shippedVersion) and restart the virtual Mac, then try again.",
                                spinning: false, dismissAfter: 12)
            }
        }
        harmonyPreparationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func finishHarmonyPreparation() {
        guard let preparation = harmonyPreparation, preparation.acknowledged,
              guestSize == preparation.target else { return }
        harmonyPreparation = nil
        harmonyPreparationTimeout?.cancel()
        harmonyPreparationTimeout = nil
        clearStatus()
        harmony = true
    }

    /// The display currently in Harmony, if any -- so the Dock menu can offer
    /// to leave it (its window is borderless and has no title bar of its own).
    static weak var harmonized: VMDisplayView?

    /// The display of the machine on screen, Harmony or not.  The Dock menu
    /// offers the guest's applications from here, so they can be reached
    /// whenever a virtual Mac is running rather than only in Harmony.
    static weak var showing: VMDisplayView?

    /// The guest's applications, kept on screen above everything else.
    private var appsPanel: GuestAppsPanel?

    /// What is in the guest's own Dock.  Harmony hides that Dock, so this is
    /// the only way back to an application that is not already running.
    private(set) var guestDockApps: [(path: String, name: String, pid: Int)] = []
    var onLaunchGuestApp: ((String) -> Void)?

    func showGuestAppsPanel() {
        let panel = appsPanel ?? GuestAppsPanel(title: machineName.isEmpty ? "Virtual Mac" : machineName)
        appsPanel = panel
        panel.present(apps: guestDockApps,
                      open: { [weak self] item in
                          if item.pid > 0 { self?.activateGuestApp(item.pid) }
                          else { self?.onLaunchGuestApp?(item.path) }
                      })
    }

    /// Keep an open panel current, and take it away with the machine.
    func refreshGuestAppsPanel() { appsPanel?.update(apps: guestDockApps) }

    /// The guest's Dock, as its tools report it.
    func setGuestDockApps(_ items: [(path: String, name: String, pid: Int)]) {
        guestDockApps = items
        // A pid of 0 means the application is in the guest's Dock but not
        // running, so only the non-zero ones say what is actually alive.
        guestDock.setRunningApplications(Set(items.filter { $0.pid > 0 }.map { $0.pid }))
        refreshGuestAppsPanel()
    }
    func closeGuestAppsPanel() { appsPanel?.close(); appsPanel = nil }

    /// What to call this machine in the panel's title bar.
    var machineName: String = ""

    var harmony = false {
        didSet {
            guard harmony != oldValue else { return }
            VMDisplayView.harmonized = harmony ? self : (VMDisplayView.harmonized === self ? nil : VMDisplayView.harmonized)
            layer?.backgroundColor = (harmony ? NSColor.clear : NSColor.black).cgColor
            screen.isOpaque = !harmony
            window?.isOpaque = !harmony
            window?.backgroundColor = harmony ? .clear : .black
            window?.hasShadow = !harmony          // one shadow per guest window, not one around them all
            if harmony {
                enterHarmonyScreen()
                if preHarmonyGuestSize == nil { preHarmonyGuestSize = guestSize }   // restore this on exit
                if let scr = window?.screen ?? NSScreen.main {
                    // Switch the guest to this Mac's exact point size, so a guest
                    // pixel is a host point and the scale is exactly 1.0 -- no
                    // fractional scaling, no coordinate rounding.  The card's
                    // EDID advertises this mode (host-native-width/height), and
                    // the device snaps the 8-px-quantized scan-out width to it.
                    // Preparation already confirmed the padded, unscaled guest canvas.
                    let menuBar = scr.frame.maxY - scr.visibleFrame.maxY   // this Mac's menu bar height
                    if !maskedDesktop {
                        harmonyManager.setActive(true, screenFrame: scr.frame,
                                                 guestSize: guestSize, hostMenuBar: menuBar)
                    }
                }
                /*
                 * The masked desktop is seamless input, not captured.
                 *
                 * Nearly every input path is gated on `engaged` -- seamless, or
                 * the mouse grabbed -- and a machine set to captured mode that
                 * is never grabbed satisfies neither.  Presses were let through
                 * while movement and, worse, *release* were dropped three
                 * levels further down: the guest was left holding the button at
                 * a pointer position it had never been told about, which
                 * suppressed everything after it.  From the outside: clicking
                 * does nothing, dragging does nothing.
                 *
                 * Saying so once here makes positioning, movement, dragging,
                 * scrolling and release all work through the paths that already
                 * exist and are already proven, instead of another special case
                 * bolted on above a door that is bolted shut below.
                 */
                if harmony {
                    ungrab()
                    preMaskedMouseMode = mouseMode
                    mouseMode = .seamless
                }
                // Masked mode has one authoritative shape: maskLayer. Applying
                // the GPU tile alpha as well punches stale holes through windows
                // during moves. Proxies still use the legacy classifier.
                channel.setHarmony(!maskedDesktop && !harmonyManager.completeWindowCapture)
                // With the mask, this window *is* the guest's windows, so it
                // keeps its own clicks -- but only where something is drawn.
                window?.ignoresMouseEvents = false
                screen.isHidden = false
                if !maskedDesktop {
                    window?.ignoresMouseEvents = true   // proxies take window clicks
                    screen.isHidden = true
                    if harmonyManager.completeWindowCapture { window?.orderOut(nil) }
                }
                if maskedDesktop { startClickThrough() }
                if showsPerformance { layoutHUDWindow() }   // the overlay needs its own window now
                updatePointerTicker()
                guestDock.start()
                if maskedDesktop { beginPointerCalibration() }
                // The clean copy of each window is taken once the guest's
                // window list has settled (see HarmonyWindowManager).
            }
            else {
                harmonyInputButtons = 0
                sendHarmonyPointer()
                stopClickThrough()
                channel.setHarmony(false)
                if let m = preMaskedMouseMode { mouseMode = m; preMaskedMouseMode = nil }
                exitHarmonyScreen()
                if let s = preHarmonyGuestSize {         // put the guest's normal resolution back
                    onHarmonyResolution?(Int(s.width), Int(s.height))
                    preHarmonyGuestSize = nil
                }
                harmonyManager.setActive(false, screenFrame: .zero, guestSize: guestSize, hostMenuBar: 0)
                window?.ignoresMouseEvents = false
                screen.isHidden = false
                restoreHUDToView()                     // the overlay goes back in the view
                updatePointerTicker()
                harmonyWindows = []; harmonyWindowList = []; harmonyHasWindows = false
                harmonyMenus.remove()                  // this Mac's own menus back
                guestDock.stop()                       // and its Dock
            }
            window?.invalidateCursorRects(for: self)
            onHarmonyChanged?(harmony)
            channel.sendToAgent?("CAPTUREMODE", harmony && !maskedDesktop ? "1" : "0")
            onHarmonyGuest?(harmony)
        }
    }

    /// Rootless Harmony: each guest window is a real macOS window (Coherence).
    let harmonyManager = HarmonyWindowManager()
    /// Rootless Harmony: the front guest application's menus, in this Mac's
    /// menu bar.
    let harmonyMenus = HarmonyMenuBar()
    /// The guest's applications in this Mac's Dock, one tile each.
    let guestDock = GuestDock()
    /// Old path (kept for reference): one sublayer per window. Unused now.
    private let harmonyContainer = CALayer()
    private var harmonyLayers: [Int: CALayer] = [:]
    private var harmonyWindowList: [(id: Int, rect: CGRect, visible: CGRect)] = []
    /// Just the rectangles (guest points, top-left), for click-through and
    /// pointer hiding.
    private var harmonyWindows: [CGRect] = []
    private var harmonyHasWindows = false
    /// Which guest application each window belongs to (for this Mac's Dock).
    private(set) var guestWindowApps: [(id: Int, pid: Int, app: String)] = []
    /// The guest's applications that have windows, and one window to raise for
    /// each -- what the Dock menu offers while Harmony is on.
    var guestApps: [(app: String, pid: Int)] {
        var seen = Set<String>(); var out: [(app: String, pid: Int)] = []
        for w in guestWindowApps where !seen.contains(w.app) {
            seen.insert(w.app); out.append((app: w.app, pid: w.pid))
        }
        return out.sorted { $0.app.localizedCaseInsensitiveCompare($1.app) == .orderedAscending }
    }
    /// The guest's windows sitting in its (hidden) Dock, so this Mac's Dock
    /// menu can offer them back.
    private(set) var minimizedGuestWindows: [(pid: Int, index: Int, title: String)] = []
    var onRestoreGuestWindow: ((Int, Int) -> Void)?
    var onMinimizeGuestWindow: ((Int) -> Void)?
    func restoreGuestWindow(_ pid: Int, _ index: Int) { onRestoreGuestWindow?(pid, index) }

    /// Bring a guest application to the front (this Mac's Dock menu).
    var onActivateGuestApp: ((Int) -> Void)?
    var onToolsStateQuery: (() -> String)?
    func activateGuestApp(_ pid: Int) { onActivateGuestApp?(pid) }
    /// While a window is dragged by its title bar, its layer holds a frozen
    /// snapshot of the window and follows the pointer -- so its pixels and its
    /// place move as one and the guest's slower report can't tear them apart.
    private var dragLayerId: Int?
    private var dragStartGuest = CGPoint.zero
    private var dragStartRect = CGRect.zero

    func setHarmonyWindows(_ windows: [(id: Int, rect: CGRect, visible: CGRect)]) {
        harmonyWindowList = windows
        harmonyWindows = windows.map { $0.rect }
        harmonyHasWindows = true
        if let scr = window?.screen ?? NSScreen.main {
            harmonyManager.setScreen(scr.frame, guestSize: guestSize)
        }
        harmonyManager.update(windows)
        updateDesktopMask()
    }

    /// Until the first window report arrives, show the whole screen (so a guest
    /// without the tools is not simply blanked); after that, only the windows.
    private func updateHarmonyVisibility() {
        if harmony, maskedDesktop {
            // The masked desktop *is* the guest's screen: it stays, and the
            // per-window layers never appear.  Without this the first window
            // report hid it again and left nothing on screen at all.
            screen.isHidden = false
            harmonyContainer.isHidden = true
            updateDesktopMask()
            return
        }
        let usingLayers = harmony && harmonyHasWindows
        screen.isHidden = usingLayers
        harmonyContainer.isHidden = !usingLayers
    }

    /// Lay out one layer per guest window: each shows just that window's part
    /// of the guest's screen, at its place on this Mac's, stacked front-most on
    /// top.  Windows that have gone are removed.
    /*
     * Cut the guest's screen to its windows exactly.
     *
     * The alpha the card publishes comes from a grid of tiles, and a tile that
     * a window's edge runs through is marked as window entire -- so a border of
     * the guest's wallpaper comes with every window, which is the frame of
     * desktop still showing round all of them.  No tile size fixes that; the
     * grid does not know where a window ends.
     *
     * The guest does, and says so: every report carries each window's exact
     * rectangle.  So the mask is built from those instead -- one path, the
     * union of the windows, laid over the screen.  Pixel-exact by construction,
     * from the same rectangles everything else already trusts.
     */
    private let maskLayer = CAShapeLayer()
    private func updateDesktopMask() {
        guard harmony, maskedDesktop, guestSize.width > 0, guestSize.height > 0 else {
            screen.mask = nil
            return
        }
        // An empty window list means no guest pixels and no input region.
        // Never reveal the entire desktop while waiting for metadata.
        let path = HarmonyDesktopGeometry.path(windows: harmonyWindowList.map { $0.rect },
                                               guestSize: guestSize, bounds: screen.bounds)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        maskLayer.frame = screen.bounds
        maskLayer.path = path
        maskLayer.fillColor = NSColor.black.cgColor
        if screen.mask !== maskLayer { screen.mask = maskLayer }
        CATransaction.commit()
        updateClickThrough()
    }

    private func buildHarmonyLayers() {
        guard harmony, guestSize.width > 0, guestSize.height > 0 else { return }
        let r = screenRect
        guard r.width > 0, r.height > 0 else { return }
        let sx = r.width / guestSize.width, sy = r.height / guestSize.height
        let gw = guestSize.width, gh = guestSize.height
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var live = Set<Int>()
        for (i, win) in harmonyWindowList.enumerated() {
            live.insert(win.id)
            if win.id == dragLayerId { continue }        // a dragged window follows the pointer, not the report
            let g = win.rect
            let l = harmonyLayers[win.id] ?? {
                let n = CALayer()
                n.masksToBounds = true
                n.magnificationFilter = .linear
                n.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                             "contentsRect": NSNull()]
                harmonyContainer.addSublayer(n)
                harmonyLayers[win.id] = n
                return n
            }()
            l.contents = lastSurface
            // View is bottom-up, guest points top-down.
            l.frame = CGRect(x: r.minX + g.minX * sx,
                             y: r.minY + (gh - (g.minY + g.height)) * sy,
                             width: g.width * sx, height: g.height * sy)
            // contentsRect is the unit rectangle of the image, y-up.
            l.contentsRect = CGRect(x: g.minX / gw, y: (gh - (g.minY + g.height)) / gh,
                                    width: g.width / gw, height: g.height / gh)
            l.cornerRadius = min(6 * sx, min(l.frame.width, l.frame.height) / 2)
            l.zPosition = CGFloat(harmonyWindowList.count - i)   // front-most first -> on top
        }
        for (id, l) in harmonyLayers where !live.contains(id) {
            l.removeFromSuperlayer(); harmonyLayers.removeValue(forKey: id)
        }
        CATransaction.commit()
    }

    /// A still image of one window's part of the guest's screen, to hold while
    /// it is dragged.
    private func windowSnapshot(_ s: IOSurfaceRef, _ g: CGRect) -> CGImage? {
        let sw = IOSurfaceGetWidth(s), sh = IOSurfaceGetHeight(s)
        IOSurfaceLock(s, .readOnly, nil); defer { IOSurfaceUnlock(s, .readOnly, nil) }
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: IOSurfaceGetBaseAddress(s), width: sw, height: sh,
                                  bitsPerComponent: 8, bytesPerRow: IOSurfaceGetBytesPerRow(s),
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
              let full = ctx.makeImage() else { return nil }
        let clip = g.intersection(CGRect(x: 0, y: 0, width: sw, height: sh))
        return full.cropping(to: clip)                   // image rows run top-down, as guest points do
    }

    /// If the pointer went down on a window's title bar, freeze that window's
    /// layer to a snapshot so it can be dragged smoothly.
    private func beginHarmonyDrag(_ e: NSEvent) {
        dragLayerId = nil
        guard harmony, harmonyHasWindows, let (gx, gy) = guestPoint(e), let s = lastSurface else { return }
        let pt = CGPoint(x: Int(gx), y: Int(gy))
        for win in harmonyWindowList where win.rect.contains(pt) {
            if pt.y <= win.rect.minY + 22, let layer = harmonyLayers[win.id], let snap = windowSnapshot(s, win.rect) {
                dragLayerId = win.id; dragStartGuest = pt; dragStartRect = win.rect
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.contents = snap
                layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                CATransaction.commit()
            }
            return                                        // front-most window under the pointer
        }
    }

    /// Move the frozen window with the pointer.
    private func updateHarmonyDrag(_ e: NSEvent) {
        guard let id = dragLayerId, let l = harmonyLayers[id], let (gx, gy) = guestPoint(e) else { return }
        let r = screenRect
        let sx = r.width / guestSize.width, sy = r.height / guestSize.height
        let g = dragStartRect.offsetBy(dx: CGFloat(gx) - dragStartGuest.x, dy: CGFloat(gy) - dragStartGuest.y)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.frame = CGRect(x: r.minX + g.minX * sx, y: r.minY + (guestSize.height - (g.minY + g.height)) * sy,
                         width: g.width * sx, height: g.height * sy)
        CATransaction.commit()
    }

    /// Let go: the window goes back to showing the live frame at wherever the
    /// guest now says it is.
    private func endHarmonyDrag() {
        guard let id = dragLayerId, let l = harmonyLayers[id] else { dragLayerId = nil; return }
        l.contents = lastSurface
        dragLayerId = nil
        buildHarmonyLayers()
    }

    /// Harmony covers this Mac's whole screen with a borderless window on the
    /// current desktop (not a separate full-screen Space, which would put
    /// nothing behind the guest to see or click).  So the guest's windows sit
    /// over this Mac's real desktop and its apps.
    private func enterHarmonyScreen() {
        guard let w = window, !w.styleMask.contains(.fullScreen),
              let screen = w.screen ?? NSScreen.main, preHarmonyFrame == nil else { return }
        preHarmonyFrame = w.frame
        preHarmonyStyle = w.styleMask
        preHarmonyLevel = w.level
        w.styleMask = [.borderless]
        w.level = .normal
        w.setFrame(screen.frame, display: true)
        // Keep this Mac's menu bar showing -- it doubles as the guest's menu
        // bar (a later stage puts the focused guest app's menus into it), and
        // the guest starts just below it so nothing is lost.  Only the Dock is
        // taken out of the way.
        NSApp.presentationOptions = []
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(self)
    }

    private func exitHarmonyScreen() {
        guard let w = window, let f = preHarmonyFrame else { return }
        NSApp.presentationOptions = []
        if let s = preHarmonyStyle { w.styleMask = s }
        if let l = preHarmonyLevel { w.level = l }
        w.setFrame(f, display: true)
        preHarmonyFrame = nil; preHarmonyStyle = nil; preHarmonyLevel = nil
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(self)
    }

    /// While harmony is on, watch the pointer and let the window pass a click
    /// straight through to this Mac wherever the guest's pixel there is
    /// see-through (its desktop), and keep it for the guest wherever the pixel
    /// is one of the guest's windows -- so its windows behave like this Mac's
    /// own and the desktop behind them is this Mac's, usable.
    private func startClickThrough() {
        stopClickThrough()
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged,
            .rightMouseDragged, .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }) { harmonyPointerMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            // Let mouseUp reach the view before reconsidering ownership.
            DispatchQueue.main.async { self?.updateClickThrough() }
            return event
        }) { harmonyPointerMonitors.append(monitor) }
        // Global monitoring can be unavailable. Also handle a moving window
        // under a stationary pointer. Common mode keeps this alive in drags.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clickThroughTimer = timer
        updateClickThrough()
    }

    private func stopClickThrough() {
        clickThroughTimer?.invalidate(); clickThroughTimer = nil
        for monitor in harmonyPointerMonitors { NSEvent.removeMonitor(monitor) }
        harmonyPointerMonitors = []
        passingThrough = false
        window?.ignoresMouseEvents = false
    }

    private func updateClickThrough() {
        guard harmony, maskedDesktop, let window else { return }
        // Keep the owner selected before mouse-down through the complete
        // gesture, including host-origin drags crossing a guest window.
        guard buttons == 0, NSEvent.pressedMouseButtons == 0 else { return }
        let p = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let onBar = (controls?.shown ?? false) && (controls?.bar.frame.contains(p) ?? false)
        let onOverlay = perf.superlayer === layer && onPerf(p)
        let pass = !onBar && !onOverlay && !guestPixelOpaque(atViewPoint: p)
        if pass != passingThrough {
            passingThrough = pass
            window.ignoresMouseEvents = pass
            harmonyDebug("PECLICK pass=\(pass) view=\(p) screen=\(screen.frame)")
        }
    }

    private func guestPixelOpaque(atViewPoint p: CGPoint) -> Bool {
        if !maskedDesktop {
            guard harmonyHasWindows else { return true }
            let r = screenRect
            guard r.width > 0, r.height > 0, r.contains(p) else { return false }
            let guest = CGPoint(x: (p.x - r.minX) / r.width * guestSize.width,
                                y: (r.maxY - p.y) / r.height * guestSize.height)
            return harmonyWindows.contains { $0.contains(guest) }
        }
        guard let layer, let path = maskLayer.path, !screen.isHidden else { return false }
        let local = screen.convert(p, from: layer)
        return screen.bounds.contains(local) && path.contains(local)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopClickThrough() }
        super.viewWillMove(toWindow: newWindow)
    }

    init(channel: DisplayChannel) {
        self.channel = channel
        super.init(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        // The toolbar hides just above the top edge and slides down into
        // view, so anything outside the screen area must be clipped away.
        layer?.masksToBounds = true
        screen.contentsGravity = .resize
        screen.isOpaque = true
        screen.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        cursor.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        cursor.anchorPoint = .zero
        cursor.isHidden = true
        cursor.magnificationFilter = .nearest
        layer?.addSublayer(screen)
        harmonyContainer.isHidden = true
        harmonyContainer.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(harmonyContainer)
        // The guest's pointer sits above the screen and the window layers, so
        // it shows over the guest's windows in Harmony (where the screen layer,
        // which used to hold it, is hidden).
        layer?.addSublayer(cursor)
        hint.string = "Click to use the mouse in the virtual Mac.  Control-Option-G gives it back."
        hint.fontSize = 12
        hint.alignmentMode = .center
        hint.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        hint.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        hint.cornerRadius = 6
        hint.isHidden = true
        layer?.addSublayer(hint)
        if let saved = UserDefaults.standard.dictionary(forKey: PerfHUD.positionKey),
           let x = saved["x"] as? Double, let y = saved["y"] as? Double {
            perfSpot = CGPoint(x: x, y: y)
        }
        layer?.addSublayer(perf)
        addSubview(status)

        // Debug driving: its own timer, so Harmony can be switched on remotely.
        if harmonyDebugFile != nil {
            debugTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.processDebugCommands() }
            }
        }
        channel.onFrame = { [weak self] s, w, h, drawn in self?.show(s, w, h, drawn) }
        channel.onCursor = { [weak self] img, hx, hy in self?.setCursor(img, hx, hy) }
        channel.onMouse = { [weak self] x, y, on in
            self?.cursorPos = CGPoint(x: x, y: y); self?.cursorOn = on; self?.placeCursor()
        }
        channel.onWindows = { [weak self] rects in self?.setHarmonyWindows(rects) }
        channel.onDragWindows = { [weak self] ids in self?.harmonyManager.setDragWindows(ids) }
        channel.onSheets = { [weak self] parents in self?.harmonyManager.setSheets(parents) }
        channel.onWindowApps = { [weak self] apps in
            self?.guestWindowApps = apps
            self?.refreshGuestAppsPanel()
            self?.harmonyManager.finderWindows = Set(apps.filter { $0.app == "Finder" }.map { $0.id })
            self?.harmonyManager.windowApplications = Dictionary(apps.filter { $0.id != 0 }.map { ($0.id, $0.pid) }, uniquingKeysWith: { _, last in last })
            self?.guestDock.setApps(apps.map { (pid: $0.pid, name: $0.app) })
        }
        channel.onMinimized = { [weak self] m in
            self?.minimizedGuestWindows = m
            self?.harmonyManager.minimizedEntries = m
        }
        harmonyManager.sendPoint = { [weak self] x, y in
            guard let self else { return }
            if self.harmonyManager.completeWindowCapture {
                self.harmonyInputPoint = CGPoint(x: x, y: y)
                self.sendHarmonyPointer()
            } else { self.sendGuestPoint(CGPoint(x: x, y: y)) }
        }
        harmonyManager.sendButton = { [weak self] bit, down in
            guard let self else { return }
            if self.harmonyManager.completeWindowCapture {
                if down { self.harmonyInputButtons |= bit } else { self.harmonyInputButtons &= ~bit }
                self.sendHarmonyPointer()
            } else { self.button(bit, down) }
        }
        harmonyManager.sendScroll = { [weak self] lines in self?.channel.send(.wheel, [lines, 0]) }
        harmonyManager.unminimize = { [weak self] pid, i in self?.onRestoreGuestWindow?(pid, i) }
        harmonyManager.minimize = { [weak self] id in self?.onMinimizeGuestWindow?(id) }
        harmonyManager.releaseInput = { [weak self] in self?.releaseAll() }
        harmonyManager.onGuestWindowFocus = { [weak self] focused in self?.harmonyMenus.setGuestWindowFocused(focused) }
        harmonyManager.requestFocus = { [weak self] id, sequence in self?.channel.sendToAgent?("FOCUSWINDOW", "\(id) \(sequence)") }
        channel.onFocusReady = { [weak self] id, sequence, ok in self?.harmonyManager.receiveFocus(id: id, sequence: sequence, ok: ok) }
        harmonyManager.raiseWindow = { [weak self] id in self?.onHarmonyRaise?(id) }
        harmonyManager.raiseWindowHard = { [weak self] id in self?.onHarmonyRaiseHard?(id) }
        harmonyManager.armFileDrag = { [weak self] id, point in self?.onArmFileDrag?(id, point) }
        harmonyManager.prepareFileDrag = { [weak self] id, done in
            guard let self, let prepare = self.onPrepareFileDrag else { done([]); return }; prepare(id, done)
        }
        harmonyManager.dropPromises = { [weak self] receivers, id in self?.onDropPromises?(receivers, id) ?? false }
        harmonyManager.dropFiles = { [weak self] urls, id in self?.onDropFiles?(urls, id) ?? false }
        harmonyManager.moveWindow = { [weak self] id, x, y in self?.onHarmonyMove?(id, x, y) }
        harmonyManager.raiseWindowAt = { [weak self] id, x, y in self?.onHarmonyRaiseAt?(id, x, y) }
        harmonyManager.moveWindowDrag = { [weak self] id, gx, gy, ex, ey in
            self?.onHarmonyMoveDrag?(id, gx, gy, ex, ey)
        }
        harmonyManager.forwardKey = { [weak self] e in self?.forwardHarmonyKey(e) }
        channel.onMenuBar = { [weak self] pid, app, tops in
            guard let self, self.harmony else { return }
            self.harmonyMenus.setMenuBar(pid: pid, app: app, tops: tops)
        }
        channel.onMenuItems = { [weak self] pid, path, items in
            self?.harmonyMenus.setItems(pid: pid, path: path, items: items)
        }
        harmonyMenus.send = { [weak self] verb, text in
            guard let self else { return }
            let payload = verb == "MENUPICK" ? text + " " + self.harmonyManager.beginMenuFocus() : text
            self.channel.sendToAgent?(verb, payload)
        }
        channel.onMenuFocus = { [weak self] token, id in self?.harmonyManager.completeMenuFocus(token, id: id) }
        channel.onFocused = { [weak self] id in self?.harmonyManager.focusedGuestWindow = id }
        channel.onOcclusion = { [weak self] o in self?.harmonyManager.setOcclusion(o) }
        channel.onAppIcon = { [weak self] pid, png in self?.guestDock.setIcon(pid: pid, png: png) }
        channel.onGuestFullscreen = { [weak self] in
            guard let self, self.harmony || self.harmonyPreparation != nil else { return }
            // The game owns its display mode. A normal exit would switch it
            // back to the pre-Harmony desktop mode and disrupt the game.
            self.preHarmonyGuestSize = nil
            self.requestHarmony(false)
            harmonyDebug("Harmony exited: guest captured its display")
        }
        channel.onHarmonyReady = { [weak self] token, size, ok in
            guard let self, let preparation = self.harmonyPreparation, preparation.token == token else { return }
            guard ok, size == preparation.target else {
                self.requestHarmony(false)
                self.showStatus("Harmony display mode is unavailable", "The guest reported \(Int(size.width)) × \(Int(size.height)). Restart the virtual Mac to load its Harmony display mode.")
                return
            }
            self.harmonyPreparation?.acknowledged = true
            self.finishHarmonyPreparation()
        }
        channel.onWindowFrame = { [weak self] data in self?.harmonyManager.receiveWindowFrame(data) }
        harmonyManager.requestWindowFrame = { [weak self] id, sequence, accepted in self?.channel.sendToAgent?("WINDOWFRAME", "\(id) \(sequence) \(accepted) rle32 tiles32") }
        guestDock.wantIcon = { [weak self] pid in self?.onWantAppIcon?(pid) }
        guestDock.activate = { [weak self] pid in
            guard let self else { return }
            if !self.harmonyManager.activateApplication(pid) { self.onActivateGuestApp?(pid) }
        }
        guestDock.openFiles = { [weak self] urls, pid in self?.onDropFilesToApp?(urls, pid) ?? false }
        guestDock.quit = { [weak self] pid in self?.onQuitGuestApp?(pid) }
    }

    private var harmonyInputPoint = CGPoint.zero
    private var harmonyInputButtons: Int32 = 0
    private func sendHarmonyPointer() {
        channel.sendToAgent?("POINTER", "\(Int(harmonyInputPoint.x.rounded())) \(Int(harmonyInputPoint.y.rounded())) \(harmonyInputButtons)")
    }

    /// A key event from a focused proxy window: run it through the same key
    /// handling as if the guest's screen had it.
    private func forwardHarmonyKey(_ e: NSEvent) {
        switch e.type {
        case .keyDown: keyDown(with: e)
        case .keyUp: keyUp(with: e)
        case .flagsChanged: flagsChanged(with: e)
        default: break
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: drawing

    /// The size to lay out for before the first frame arrives.
    func setGuestSize(_ size: CGSize) {
        guestSize = size
        needsLayout = true
    }

    /*
     * The first moments belong to the firmware, which paints the screen its
     * own color before Mac OS X takes over.  A real Mac shows nothing at
     * all until the Apple appears, so the window stays black for a beat
     * rather than flashing that up.
     */
    private let started = Date()
    private var firmwareHidden = true
    private var firmwareTimer: Timer?
    /// The last frame that arrived while the screen was held black.
    private var held: (surface: IOSurfaceRef, width: Int, height: Int)?
    private static let firmwareBlank: TimeInterval = 2.5

    /// A machine being woken has no firmware to hide: the first thing it
    /// draws is the desktop it fell asleep on, and holding that back would
    /// only make waking look slower than it is.
    func expectRestoredFrame() {
        firmwareHidden = false
        firmwareTimer?.invalidate()
        firmwareTimer = nil
    }

    /// Say what is happening over the screen.  `untilFirstFrame` takes the
    /// message away the moment the guest has something to show.
    /*
     * `dismissible` is for a status that reports a failure rather than
     * progress.  Nothing else clears one of those: clearStatus() is called
     * when Harmony is turned off or finishes, and neither happens after a
     * failure, so the overlay stayed up for the rest of the session with
     * no way past it.  A dismissible status goes away on its own, and on
     * the next thing the reader does.
     */
    private var statusDismissTimer: DispatchWorkItem?
    private(set) var statusDismissible = false

    func showStatus(_ text: String, _ note: String? = nil, untilFirstFrame: Bool = false,
                    spinning: Bool = true, dismissAfter: TimeInterval? = nil) {
        statusUntilFrame = untilFirstFrame
        status.show(text, note, spinning: spinning)
        statusDismissTimer?.cancel()
        statusDismissTimer = nil
        statusDismissible = dismissAfter != nil
        if let after = dismissAfter {
            let work = DispatchWorkItem { [weak self] in self?.clearStatus() }
            statusDismissTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
        }
    }

    /// Clear a status the reader is allowed to dismiss, and say whether one
    /// was there.  The display view calls this on a click or a key.
    @discardableResult
    func dismissStatusIfAllowed() -> Bool {
        guard statusDismissible else { return false }
        clearStatus()
        return true
    }

    func clearStatus() {
        statusUntilFrame = false
        statusDismissible = false
        statusDismissTimer?.cancel()
        statusDismissTimer = nil
        status.hideStatus()
    }

    private func show(_ s: IOSurfaceRef, _ w: Int, _ h: Int, _ drawn: CGRect) {
        if firmwareHidden {
            let left = Self.firmwareBlank - Date().timeIntervalSince(started)
            if left > 0 {
                // Held back, not thrown away.  A machine that stops drawing
                // during the blank -- the firmware reaching its own prompt
                // and waiting, which is what a disc that will not boot
                // leaves on the screen -- would otherwise leave the window
                // black for ever, because no later frame ever arrives to
                // replace the ones that were dropped.
                held = (s, w, h)
                if firmwareTimer == nil {
                    firmwareTimer = Timer.scheduledTimer(withTimeInterval: left, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.firmwareHidden = false
                            self.firmwareTimer = nil
                            if let h = self.held {
                                self.held = nil
                                // Held back over the firmware blank: nothing is
                                // known about what changed, so take it all.
                                self.show(h.surface, h.width, h.height,
                                          CGRect(x: 0, y: 0, width: h.width, height: h.height))
                            }
                        }
                    }
                }
                return
            }
            firmwareHidden = false
            held = nil
        }
        if statusUntilFrame { clearStatus() }
        let size = CGSize(width: w, height: h)
        if size != guestSize {
            guestSize = size
            fitX.reset(); fitY.reset(); pointerFitText = "measuring"   // scale is per-mode
            (window?.windowController as? VMWindowController)?.guestResized(size)
            needsLayout = true
        }
        finishHarmonyPreparation()
        screen.contents = s
        lastSurface = s
        if harmony {
            harmonyManager.setSurface(s)
            // Redraw follows the guest's frames, and only where it drew.
            harmonyManager.currentFrameSeq = channel.frameSeq
            /*
             * The whole guest screen as it arrived, before Harmony cuts it up.
             * Timing a keystroke against this and against a window's own copy
             * separates what the emulated Mac took to draw from what showing
             * it costs -- which the brief asks for separately, and which
             * nothing so far could tell apart.
             */
            if ProcessInfo.processInfo.environment["POWEREMU_DUMP_SCREEN"] != nil {
                // A checksum, not the pixels.  Writing seven megabytes a frame
                // to time something measured in milliseconds changes the answer:
                // it put forty milliseconds on the figure it was meant to explain.
                let h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s)
                IOSurfaceLock(s, .readOnly, nil)
                if let b = IOSurfaceGetBaseAddress(s) as UnsafeMutableRawPointer? {
                    var sum: UInt64 = 1469598103934665603
                    for y in stride(from: 0, to: h, by: 3) {
                        for x in stride(from: 0, to: bpr, by: 64) {
                            sum = (sum ^ UInt64(b.load(fromByteOffset: y * bpr + x, as: UInt8.self)))
                                &* 1099511628211
                        }
                    }
                    try? "\(sum)".write(toFile: "/tmp/pescreen.sum",
                                        atomically: false, encoding: .utf8)
                }
                IOSurfaceUnlock(s, .readOnly, nil)
            }
            harmonyManager.refreshLiveCopies(damaged: drawn)
        }
    }

    /// The guest's screen, as large as fits (below the notch in fullscreen),
    /// in whole multiples when it fits that way so pixels stay sharp.
    var screenRect: CGRect {
        let i = safeAreaInsets
        let area = CGRect(x: bounds.minX + i.left, y: bounds.minY + i.bottom,
                          width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom)
        guard guestSize.width > 0, guestSize.height > 0 else { return area }
        let fitX = area.width / guestSize.width, fitY = area.height / guestSize.height
        var sx: CGFloat, sy: CGFloat
        switch displayFit {
        case "stretch":
            // Each axis fills independently: the shape is not kept.
            sx = fitX; sy = fitY
        case "fill":
            // Keep the shape and lose the border; the overflow is cropped by
            // the view, which clips.
            sx = max(fitX, fitY); sy = sx
        default:
            sx = min(fitX, fitY); sy = sx
        }
        if displayFit != "stretch" {
            // These two only make sense while both axes share a scale.
            if scaling == "integer" {
                // Whole multiples only, so every guest pixel is the same size
                // square.  Below 1:1 there is nothing to round to -- the
                // guest's screen is larger than the window -- so fit as usual.
                if sx >= 1 { sx = sx.rounded(.down); sy = sx }
            } else if sx > 1 && sx < 1.1 {
                sx = 1; sy = 1                          // a little border beats a blurry screen
            }
        }
        // Overscan last, so it is a deliberate push past whatever was chosen
        // rather than something the integer rounding above can swallow.
        if overscan != 0 {
            let zoom = 1 + CGFloat(overscan) / 100
            sx *= zoom; sy *= zoom
        }
        let w = (guestSize.width * sx).rounded(), h = (guestSize.height * sy).rounded()
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h).integral
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Fill and positive overscan put the picture past the view's edges on
        // purpose; without clipping it would be drawn over the rest of the
        // window instead of being cropped by it.
        layer?.masksToBounds = true
        screen.frame = screenRect
        updateDesktopMask()          // its geometry follows this layer's
        if harmony, let scr = window?.screen ?? NSScreen.main {
            harmonyManager.setScreen(scr.frame, guestSize: guestSize)
            harmonyManager.update(harmonyWindowList)
        }
        /*
         * Nearest keeps every guest pixel a hard-edged block; linear softens
         * it.  "smooth" is the long-standing behaviour -- nearest only when
         * the scale is exactly 1:1, where linear would blur for nothing.
         */
        let exact = screen.frame.width == guestSize.width
        let nearest = scaling != "smooth" || exact
        screen.magnificationFilter = nearest ? .nearest : .linear
        screen.minificationFilter = scaling == "smooth" ? .linear : .nearest
        let hs = CGSize(width: 480, height: 22)
        hint.frame = CGRect(x: bounds.midX - hs.width / 2, y: 16, width: hs.width, height: hs.height)
        status.frame = bounds
        layoutPerf()
        // The bar places itself: shown, it sits over the top of the guest's
        // screen; hidden, just above the edge, ready to slide down.
        if let controls { controls.place(in: self, shown: controls.shown, animated: false) }
        CATransaction.commit()
        placeCursor()
        window?.invalidateCursorRects(for: self)
    }

    private func setCursor(_ img: CGImage?, _ hx: Int, _ hy: Int) {
        harmonyManager.setGuestCursor(img, hotSpot: CGPoint(x: hx, y: hy))
        cursor.contents = img
        cursorSize = img.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        cursorHot = CGPoint(x: hx, y: hy)
        placeCursor()
    }

    /// Guest pixels (origin top left) to the screen layer (origin bottom left).
    private func placeCursor() {
        if harmony && !maskedDesktop { cursor.isHidden = true; return }
        // In Harmony the pointer must ride the very transform the windows use
        // (scale + menu-bar offset, anchored at the screen's top-left) -- not
        // the fitted/centered screenRect -- or it is drawn off the window it is
        // actually on, and a click looks like it lands somewhere else.
        if harmony && harmonyHasWindows {
            let s = harmonyManager.guestScale
            let tl = harmonyManager.viewPoint(forGuest: CGPoint(x: cursorPos.x - cursorHot.x,
                                                                y: cursorPos.y - cursorHot.y))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            cursor.bounds = CGRect(origin: .zero, size: CGSize(width: cursorSize.width * s,
                                                               height: cursorSize.height * s))
            cursor.position = CGPoint(x: tl.x, y: tl.y - cursorSize.height * s)
            let overWindow = harmonyWindows.contains { $0.contains(cursorPos) }
            cursor.isHidden = !cursorOn || cursor.contents == nil || !overWindow
            CATransaction.commit()
            return
        }
        let r = screenRect
        let scale = guestSize.width > 0 ? r.width / guestSize.width : 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cursor.bounds = CGRect(origin: .zero, size: CGSize(width: cursorSize.width * scale, height: cursorSize.height * scale))
        // The cursor layer now lives in the view, not inside the screen layer,
        // so its place is offset by where the guest's screen sits in the view.
        let x = r.minX + (cursorPos.x - cursorHot.x) * scale
        let top = (cursorPos.y - cursorHot.y) * scale
        cursor.position = CGPoint(x: x, y: r.minY + r.height - top - cursorSize.height * scale)
        // In Harmony the guest's pointer belongs only over its own windows;
        // over the masked-away desktop this Mac's pointer shows instead.
        let overWindow = harmonyWindows.contains { $0.contains(cursorPos) }
        cursor.isHidden = !cursorOn || cursor.contents == nil
            || (harmony && harmonyHasWindows && !overWindow)
        CATransaction.commit()
    }

    // MARK: the performance overlay

    /// Developer testing: POWEREMU_TEST_HUD=1 shows the overlay as soon as
    /// a machine's window opens, POWEREMU_TEST_TOOLBAR=1 the toolbar.
    func showPerformanceForTesting() {
        let env = ProcessInfo.processInfo.environment
        if env["POWEREMU_TEST_HUD"] != nil && !showsPerformance {
            togglePerformance()
        }
        if env["POWEREMU_TEST_TOOLBAR"] != nil {
            controls?.reveal()
        }
    }

    func togglePerformance() {
        if let t = perfTimer {
            t.invalidate(); perfTimer = nil; perf.isHidden = true; lastPerf = nil
            restoreHUDToView()
            updatePointerTicker()          // Harmony may still need the tick
            return
        }
        fpsHistory.reset(); windowHistory.reset(); emuHistory.reset(); drawHistory.reset()
        cpuPerformance.reset(); cpuHistories.removeAll()
        perf.update(rows: [], lines: ["Measuring…"])
        perf.isHidden = false
        needsLayout = true
        samplePerformance()
        perfTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePerformance() }
        }
        // The pointer readout has to keep up with the mouse, not with the
        // once-a-second sampling.
        updatePointerTicker()
    }

    /// The tick runs while Harmony is on (to keep the pointer correction
    /// calibrated) or while the overlay is shown; it stops when neither needs it.
    private func updatePointerTicker() {
        let want = harmony || showsPerformance
        if want, hudTicker == nil {
            hudTicker = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerTick() }
            }
        } else if !want {
            hudTicker?.invalidate(); hudTicker = nil
        }
    }

    /// Put the overlay where the reader last dragged it, or under the top
    /// of the window -- below the menu bar in full screen, which is what
    /// the safe area describes.
    private func layoutPerf() {
        let size = perf.wantedSize
        let i = safeAreaInsets
        let area = CGRect(x: bounds.minX + i.left + 10, y: bounds.minY + i.bottom + 10,
                          width: max(1, bounds.width - i.left - i.right - 20 - size.width),
                          height: max(1, bounds.height - i.top - i.bottom - 20 - size.height))
        let spot = perfSpot ?? CGPoint(x: 0, y: 1)          // top left by default
        let x = area.minX + area.width * min(1, max(0, spot.x))
        let y = area.minY + area.height * min(1, max(0, spot.y))
        perf.frame = CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    /// Whether a point is on the overlay, which the reader can drag.
    private func onPerf(_ p: CGPoint) -> Bool {
        !perf.isHidden && perf.frame.contains(p)
    }

    /// Remember where it was dragged to, as a fraction of the space it can
    /// move in, so it keeps its place when the window changes size.
    private func rememberPerfSpot() {
        let size = perf.wantedSize
        let i = safeAreaInsets
        let w = max(1, bounds.width - i.left - i.right - 20 - size.width)
        let h = max(1, bounds.height - i.top - i.bottom - 20 - size.height)
        let spot = CGPoint(x: (perf.frame.minX - (bounds.minX + i.left + 10)) / w,
                           y: (perf.frame.minY - (bounds.minY + i.bottom + 10)) / h)
        perfSpot = spot
        UserDefaults.standard.set(["x": spot.x, "y": spot.y], forKey: PerfHUD.positionKey)
    }

    private func samplePerformance() {
        let shown = channel.framesShown
        queryPerf? { [weak self] text in
            DispatchQueue.main.async { self?.updatePerformance(text, shown: shown) }
        }
    }

    private func updatePerformance(_ text: String?, shown: Int) {
        guard perfTimer != nil, let text else { return }
        var v: [String: Double] = [:]
        for kv in text.split(separator: " ") {
            let p = kv.split(separator: "=")
            if p.count == 2, let d = Double(p[1]) { v[String(p[0])] = d }
        }
        let now = ProcessInfo.processInfo.systemUptime
        let cur = (time: now, frames: v["frames"] ?? 0, draws: v["draws"] ?? 0, shown: shown,
                   texVRAM: v["tex_vram"] ?? 0, texAGP: v["tex_agp"] ?? 0, agpBytes: v["agp_bytes"] ?? 0)
        defer { lastPerf = cur }
        guard let last = lastPerf, now > last.time else { return }
        let dt = now - last.time
        let fps = (cur.frames - last.frames) / dt
        let draws = (cur.draws - last.draws) / dt
        let shownRate = Double(cur.shown - last.shown) / dt
        let tv = cur.texVRAM - last.texVRAM, ta = cur.texAGP - last.texAGP
        let agpShare = tv + ta > 0 ? 100 * ta / (tv + ta) : 0
        let agpMB = (cur.agpBytes - last.agpBytes) / dt / 1_048_576
        let mb = 1_048_576.0
        /*
         * The host line is the reason this overlay grew. Guest figures alone
         * cannot tell a slow build from a busy Mac, and more than once a
         * perfectly good build has been judged while something else was
         * eating the cores or the machine was throttling.
         */
        let h = hostStats.sample(qemuPID: qemuPID?())
        let cpuReadings = cpuPerformance.sample(v)
        let warn = h.contended ? "  << High host load: timings may be affected" :
            (h.thermal == .nominal ? "" : "  << THERMAL \(h.thermalText)")

        fpsHistory.add(fps)
        windowHistory.add(shownRate)
        emuHistory.add(h.qemuCPU)
        drawHistory.add(draws)

        /*
         * The lowest and highest matter more than the average: a guest that
         * sits at 30 and drops to 4 for a moment every second feels nothing
         * like a steady 30, and only the range shows it.
         */
        let range = fpsHistory.hasRange
            ? String(format: "%.0f fps   (%.0f low, %.0f high)", fps, fpsHistory.lowest, fpsHistory.highest)
            : String(format: "%.0f fps", fps)
        var rows: [PerfHUD.Row] = [
            .init(title: "Guest", value: range,
                  history: fpsHistory.values, scale: fpsHistory.scale(atLeast: 30), tint: .systemGreen),
            .init(title: "Window", value: String(format: "%.0f fps", shownRate),
                  history: windowHistory.values, scale: max(60, windowHistory.scale(atLeast: 60)),
                  tint: .systemTeal),
            .init(title: "Draws", value: String(format: "%.0f/s", draws),
                  history: drawHistory.values, scale: drawHistory.scale(atLeast: 1000), tint: .systemPurple),
            .init(title: "Emulator", value: String(format: "%.0f%% host CPU", h.qemuCPU),
                  history: emuHistory.values, scale: emuHistory.scale(atLeast: Double(max(1, cpuPerformance.count)) * 100), tint: .systemOrange),
        ]
        for reading in cpuReadings {
            if let percent = reading.percent {
                cpuHistories[reading.index, default: PerfHistory()].add(percent)
            } else {
                cpuHistories[reading.index] = PerfHistory()
            }
            rows.append(.init(title: "CPU \(reading.index + 1)",
                              value: reading.percent.map { String(format: "%.0f%% host core", $0) }
                                  ?? (cpuPerformance.shared ? "shared thread" : "measuring…"),
                              history: cpuHistories[reading.index]?.values ?? [],
                              scale: 100, tint: reading.index == 0 ? .systemBlue : .systemPink,
                              graph: reading.percent != nil))
        }
        if fpsHistory.values.count < 2 {
            rows = rows.map { var r = $0; r.graph = false; return r }
        }
        var lines = [
            String(format: "VRAM peak %.1f of %.0f MB   textures from AGP %.0f%% (%.1f MB/s)",
                   (v["vram_high"] ?? 0) / mb, (v["vram_usable"] ?? 0) / mb, agpShare, agpMB),
            String(format: "This Mac %.0f%% busy   load %.1f of %d   thermal %@",
                   h.hostBusy, h.load1, h.cores, h.thermalText as NSString),
        ]
        lines.append(cpuReadings.isEmpty ? "CPU detail unavailable"
                     : "CPU graphs: host execution time; each core = 100%")
        if !warn.isEmpty { lines.append(warn.trimmingCharacters(in: .whitespaces)) }
        hudRows = rows; hudLines = lines
        refreshHUD()
        captureExperimentViewIfRequested()
    }


    /// Test-only export of this app's own live display layers and HUD.
    /// Does not capture other windows or request screen-recording access.
    private func captureExperimentViewIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["POWEREMU_TEST_SNAPSHOT"],
              FileManager.default.fileExists(atPath: path + ".request"),
              let surface = lastSurface, let root = layer,
              let guest = windowSnapshot(surface, CGRect(x: 0, y: 0,
                  width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))) else { return }
        try? FileManager.default.removeItem(atPath: path + ".request")
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let previous = screen.contents
        screen.contents = guest
        root.displayIfNeeded()
        perf.displayIfNeeded()
        root.render(in: context)
        screen.contents = previous
        CATransaction.commit()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        let report = hudRows.map { ["title": $0.title, "value": $0.value] }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path + ".json"))
        }
    }

    // MARK: the overlay's pointer readout

    /// Where the pointer is on this Mac, what that maps to in the guest (what a
    /// click sends), and where the guest says its own pointer is.  When the
    /// last two disagree the mapping is wrong, and by how much.
    /// Send a point the guest should end up at, corrected for the guest's own
    /// scaling of its tablet area.  Everything that points the guest goes
    /// through here -- Harmony and seamless alike.
    func sendGuestPoint(_ g: CGPoint) {
        var out = g
        if let (kx, bx) = fitX.solved { out.x = (g.x - bx) / kx }
        if let (ky, by) = fitY.solved { out.y = (g.y - by) / ky }
        // Never aim outside the guest's screen: it clamps, and a clamped
        // sample would poison the fit.
        out.x = min(max(0, out.x), max(0, guestSize.width - 1))
        out.y = min(max(0, out.y), max(0, guestSize.height - 1))
        lastRawSent = out
        channel.send(.point, [Int32(out.x.rounded()), Int32(out.y.rounded())])
    }

    /// Walk a few points across the guest's screen and watch where its pointer
    /// actually lands, to measure the tablet's scaling straight away.
    func beginPointerCalibration() {
        guard guestSize.width > 1, guestSize.height > 1 else { return }
        fitX.reset(); fitY.reset()
        let fx: [CGFloat] = [0.12, 0.88, 0.20, 0.80, 0.50, 0.30, 0.70, 0.40, 0.60, 0.15, 0.85]
        let fy: [CGFloat] = [0.20, 0.25, 0.80, 0.75, 0.50, 0.65, 0.35, 0.30, 0.70, 0.55, 0.45]
        probePoints = zip(fx, fy).map { CGPoint(x: guestSize.width * $0, y: guestSize.height * $1) }
        probeAt = 0; probeTicks = 0
        pointerFitText = "calibrating"
    }

    /// One step per tick: send a probe, give the guest a moment, record where
    /// its pointer ended up, move on.
    private func stepPointerCalibration() {
        guard probeAt < probePoints.count else { return }
        if probeTicks >= 10 { probeSettled = cursorPos }         // remember it a tick early
        probeTicks += 1
        if probeTicks == 1 {
            let g = probePoints[probeAt]
            lastRawSent = g
            channel.send(.point, [Int32(g.x.rounded()), Int32(g.y.rounded())])   // uncorrected
            return
        }
        guard probeTicks >= 11 else { return }                  // ~0.7s: the guest is slow to catch up
        if let sent = lastRawSent,
           cursorPos.x > 0, cursorPos.y > 0,
           cursorPos.x < guestSize.width - 1, cursorPos.y < guestSize.height - 1,
           cursorPos == probeSettled {                          // two ticks the same: it has stopped
            fitX.add(sent.x, cursorPos.x); fitY.add(sent.y, cursorPos.y)
            harmonyDebug("PECAL probe sent=(\(Int(sent.x)),\(Int(sent.y))) got=(\(Int(cursorPos.x)),\(Int(cursorPos.y)))")
        }
        probeAt += 1; probeTicks = 0
        if probeAt >= probePoints.count {
            if let (kx, _) = fitX.solved, let (ky, _) = fitY.solved {
                pointerFitText = String(format: "k %.3f,%.3f calibrated", kx, ky)
                harmonyDebug(String(format: "PECAL done kx=%.4f ky=%.4f n=%.0f", kx, ky, fitX.n))
            } else {
                pointerFitText = "calibration failed"
                harmonyDebug("PECAL failed")
            }
        }
    }

    /// Once the pointer and the guest have both stopped moving, the pair
    /// (what was sent, where it landed) is a clean, lag-free measurement.
    private func samplePointerFit() {
        guard probeAt >= probePoints.count, let sent = lastRawSent else { return }
        let h = NSEvent.mouseLocation
        defer { lastSettleHost = h; lastSettleGuest = cursorPos }
        guard h == lastSettleHost, cursorPos == lastSettleGuest else { return }   // still settling
        // A clamped landing says nothing about the scale.
        guard cursorPos.x > 0, cursorPos.y > 0,
              cursorPos.x < guestSize.width - 1, cursorPos.y < guestSize.height - 1 else { return }
        fitX.add(sent.x, cursorPos.x)
        fitY.add(sent.y, cursorPos.y)
        if let (kx, _) = fitX.solved, let (ky, _) = fitY.solved {
            pointerFitText = String(format: "k %.3f,%.3f from %.0f", kx, ky, fitX.n)
        }
    }

    /// POWEREMU_HARMONY_DEBUG=1: the same readout, into the system log, as the
    /// pointer moves -- so the mapping can be watched from outside the machine
    /// rather than read off the screen.
    private var lastLoggedPointer = CGPoint(x: -9e9, y: -9e9)
    private func logPointer() {
        guard ProcessInfo.processInfo.environment["POWEREMU_HARMONY_DEBUG"] != nil else { return }
        // Log every tick, moving or not: the settled reading while the pointer
        // is held still is the one measurement with no lag in it.
        let h = NSEvent.mouseLocation
        lastLoggedPointer = h
        let want = harmonyManager.guestPointAtCursor()
        harmonyDebug(String(format: "PEPOINTER mac=%.0f,%.0f sent=%.0f,%.0f guest=%.0f,%.0f off=%+.0f,%+.0f scale=%.3f offY=%.0f surf=%.0fx%.0f harmony=%d",
              h.x, h.y, want.x, want.y, cursorPos.x, cursorPos.y,
              cursorPos.x - want.x, cursorPos.y - want.y,
              harmonyManager.guestScale, harmonyManager.guestOffsetY,
              guestSize.width, guestSize.height, harmony ? 1 : 0))
    }

    private func pointerLine() -> String {
        let h = NSEvent.mouseLocation
        let want = harmonyManager.guestPointAtCursor()
        return String(format: "Pointer  this Mac %.0f,%.0f   sent %.0f,%.0f   guest %.0f,%.0f   off %+.0f,%+.0f",
                      h.x, h.y, want.x, want.y, cursorPos.x, cursorPos.y,
                      cursorPos.x - want.x, cursorPos.y - want.y)
    }

    /// Redraw the overlay with a fresh pointer line, in whichever place it
    /// lives: its own window while Harmony is on (the guest's windows are real
    /// windows above this one, so a layer in here would be behind them), or
    /// this view otherwise.
    /*
     * POWEREMU_HARMONY_DEBUG=1 only: a command file, so Harmony can be driven
     * and checked without a hand on the mouse.  Write lines to
     * /tmp/poweremu-harmony-cmd:
     *     windows              list the guest's windows into the log
     *     move <id> <x> <y>    ask the guest to move one
     *     raise <id>           bring one to the front
     *     harmony on|off       toggle Harmony
     *     overlay on|off       toggle the overlay
     */
    private func processDebugCommands() {
        guard harmonyDebugFile != nil else { return }
        let path = ProcessInfo.processInfo.environment["POWEREMU_HARMONY_COMMAND_PATH"]
            ?? "/tmp/poweremu-harmony-cmd"
        guard let txt = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        for line in txt.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            guard let cmd = f.first else { continue }
            switch cmd {
            case "windows":
                harmonyDebug("PEWIN count=\(harmonyWindowList.count) harmony=\(harmony)")
                for w in harmonyWindowList {
                    let hf = harmonyManager.hostFrameFor(w.rect)
                    harmonyDebug("PEWIN id=\(w.id) guest=(\(Int(w.rect.minX)),\(Int(w.rect.minY)),\(Int(w.rect.width)),\(Int(w.rect.height))) host=(\(Int(hf.minX)),\(Int(hf.minY)),\(Int(hf.width)),\(Int(hf.height))) vis=(\(Int(w.visible.minX)),\(Int(w.visible.minY)),\(Int(w.visible.width)),\(Int(w.visible.height))) \(harmonyManager.liveness(w.id))")
                }
            case "move" where f.count >= 4:
                if let id = Int(f[1]), let x = Int(f[2]), let y = Int(f[3]) {
                    harmonyDebug("PECMD move id=\(id) -> (\(x),\(y))")
                    harmonyManager.requestGuestMove(id, to: CGPoint(x: x, y: y))
                }
            case "point" where f.count >= 3:
                if let x = Double(f[1]), let y = Double(f[2]) {
                    harmonyDebug("PECMD point -> (\(Int(x)),\(Int(y)))")
                    sendGuestPoint(CGPoint(x: x, y: y))
                }
            case "resolution" where f.count >= 3:
                if let w = Int(f[1]), let h = Int(f[2]) {
                    harmonyDebug("PECMD resolution \(w)x\(h)")
                    onHarmonyResolution?(w, h)
                }
            case "tools":
                harmonyDebug("PETOOLS \(String(describing: onToolsStateQuery?() ?? "unknown"))")
            case "recapture":
                harmonyManager.beginInitialCapture()
            case "snap" where f.count >= 2:
                if let id = Int(f[1]) {
                    harmonyDebug("PESNAP " + harmonyManager.writeSnapshot(id, to: "/tmp/pe-snap-\(id).png"))
                }
            case "stack":
                harmonyDebug("PEHOSTSTACK " + harmonyManager.hostStackReport())
            case "proxies":
                harmonyDebug("PEPROXY " + harmonyManager.proxyReport())
            case "minimized":
                harmonyDebug("PEMIN " + minimizedGuestWindows
                    .map { "\($0.title)#\($0.pid)/\($0.index)" }.joined(separator: ", "))
            case "testmin" where f.count >= 2:
                if let id = Int(f[1]) { harmonyDebug("PETESTMIN " + harmonyManager.testMiniaturize(id)) }
            case "drop" where f.count >= 2:
                // The same path a real drag takes, without the drag.
                let path = f.dropFirst().joined(separator: " ")
                harmonyDebug("PEDROP test \(path)")
                onDropFiles?([URL(fileURLWithPath: path)], 0)
            case "absorb" where f.count >= 2:
                harmonyManager.liveAbsorb = (f[1] == "on")
                harmonyDebug("PEABSORB \(harmonyManager.liveAbsorb)")
            case "mask" where f.count >= 2:
                harmonyManager.liveMasking = (f[1] == "on")
                harmonyDebug("PEMASK \(harmonyManager.liveMasking)")
            case "rate":
                harmonyDebug(harmonyManager.copyRate())
            case "menus":
                harmonyDebug(harmonyMenus.report)
                harmonyDebug("PEMAINMENU " + (NSApp.mainMenu?.items.map { $0.title } ?? []).joined(separator: " | "))
            case "menuitems" where f.count >= 2:
                harmonyMenus.openForTest(f[1])
            case "menudump" where f.count >= 2:
                harmonyDebug("PEMENUDUMP " + harmonyMenus.dump(f[1]))
            case "menupick" where f.count >= 2:
                harmonyMenus.pickForTest(f[1])
            case "apps":
                harmonyDebug("PEAPPS " + guestApps.map { "\($0.app)#\($0.pid)" }.joined(separator: ", "))
            case "raise" where f.count >= 2:
                if let id = Int(f[1]) { harmonyDebug("PECMD raise \(id)"); harmonyManager.proxyRaise(id) }
            case "harmony" where f.count >= 2:
                harmonyDebug("PECMD harmony \(f[1])"); requestHarmony(f[1] == "on")
            case "overlay" where f.count >= 2:
                let want = f[1] == "on"
                if want != showsPerformance { togglePerformance() }
                harmonyDebug("PECMD overlay \(f[1])")
            default:
                harmonyDebug("PECMD unknown: \(line)")
            }
        }
    }

    /// 15 Hz: keep the correction calibrated, and the overlay fresh if shown.
    private func pointerTick() {
        processDebugCommands()
        // In Harmony the proxies hold the focus, so a modifier let go of while
        // the focus is elsewhere never reaches the guest and sticks down --
        // which reads in the guest as shift- or command-clicking.  Reconcile
        // with what is really held, every tick.
        if harmony { syncModifiers(NSEvent.modifierFlags) }
        stepPointerCalibration()
        samplePointerFit()
        refreshHUD()
    }

    private func refreshHUD() {
        guard showsPerformance else { return }
        var lines = hudLines
        lines.append(pointerLine())
        logPointer()
        if harmony {
            lines.append(String(format: "Harmony  scale %.3f   offset %.0f   guest screen %.0fx%.0f   tablet %@",
                                harmonyManager.guestScale, harmonyManager.guestOffsetY,
                                guestSize.width, guestSize.height, pointerFitText as NSString))
            /*
             * Two lines that say whether windows are being refreshed and, if
             * not, which of the reasons is stopping them -- the same figures
             * the log carries, put where a screenshot will pick them up.
             */
            let d = harmonyManager.diag
            lines.append(String(format:
                "  windows %d   copies %d/s   frames %.1f/s   frame #%d   worst %d frames behind   oldest %.1fs   %d over 2s%@",
                d.windows, d.copies, d.fps, d.publishedSeq, d.worstSeqLag, d.worstAge, d.olderThan2s,
                (d.inSync ? "" : "   OCCLUSION BEHIND") as NSString))
            lines.append(String(format:
                "  held back:  covered %d   nothing drawn %d   settling %d   stale pass %d   too new %d   pointer %d/s (%d dropped)   clicks %d   occl %d/s   mask-refused %d",
                d.covered, d.noDamage, d.settling, d.stale, d.notFresh,
                d.pointerSent, d.pointerDropped, d.clicks, d.occlPerSec, d.desktopSkips))
        }
        perf.update(rows: hudRows, lines: lines)
        if harmony { layoutHUDWindow() } else { layoutPerf() }
    }

    /// Harmony: the overlay gets its own floating window, above the guest's
    /// proxy windows.
    private func layoutHUDWindow() {
        guard harmony, showsPerformance, let scr = window?.screen ?? NSScreen.main else { return }
        let size = perf.wantedSize
        if hudWindow == nil {
            let w = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .floating                 // the proxies are .normal
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            let v = NSView(frame: CGRect(origin: .zero, size: size))
            v.wantsLayer = true
            v.layer = CALayer()
            w.contentView = v
            hudWindow = w
        }
        guard let hw = hudWindow, let hv = hw.contentView else { return }
        if perf.superlayer !== hv.layer {
            perf.removeFromSuperlayer()
            hv.layer?.addSublayer(perf)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hw.setFrame(CGRect(x: scr.frame.minX + 12,
                           y: scr.frame.maxY - harmonyManager.hostMenuBar - 12 - size.height,
                           width: size.width, height: size.height), display: true)
        perf.frame = CGRect(origin: .zero, size: size)
        CATransaction.commit()
        hw.orderFront(nil)
    }

    /// Put the overlay back in this view and drop its window.
    private func restoreHUDToView() {
        if perf.superlayer !== layer {
            perf.removeFromSuperlayer()
            layer?.addSublayer(perf)
        }
        hudWindow?.orderOut(nil)
        hudWindow = nil
        needsLayout = true
    }

    // MARK: the mouse

    /// Seamless: the pointer moves in and out of the virtual Mac freely (a
    /// USB tablet in the guest takes absolute positions).  Captured: a click
    /// takes the mouse and sends raw movement, for games that turn the view
    /// with it; Control-Option-G gives it back.
    enum MouseMode: String { case seamless, captured }

    /// VMConfig.panelFilter: period display emulation, 0 for off.
    var panelFilter: Int = 0 {
        didSet { guard panelFilter != oldValue else { return }; applyPanelFilter() }
    }

    /*
     * The filter goes on the screen layer, so it costs one GPU pass over a
     * layer that is already being composited and nothing on the CPU.  The
     * guest's own size is handed to the kernel because the scanlines and the
     * phosphor mask belong on the guest's pixels, not on this Mac's.
     */
    private func applyPanelFilter() {
        guard panelFilter > 0, PanelFilters.kernel != nil else {
            screen.filters = nil
            return
        }
        let f = PanelFilter()
        f.inputMode = NSNumber(value: panelFilter)
        f.inputWidth = NSNumber(value: Double(guestSize.width))
        f.inputHeight = NSNumber(value: Double(guestSize.height))
        screen.filters = [f]
    }

    /// VMConfig.scaling: "smooth", "sharp" or "integer".  See the note there.
    var scaling: String = "smooth" {
        didSet { guard scaling != oldValue else { return }; needsLayout = true }
    }

    /// VMConfig.displayFit: "fit", "fill" or "stretch".  See the note there.
    var displayFit: String = "fit" {
        didSet { guard displayFit != oldValue else { return }; needsLayout = true }
    }

    /// VMConfig.overscan: percent past the fit; positive crops, negative insets.
    var overscan: Double = 0 {
        didSet { guard overscan != oldValue else { return }; needsLayout = true }
    }

    var mouseMode: MouseMode = .seamless {
        didSet {
            ungrab()
            window?.invalidateCursorRects(for: self)
            flashHint(false)
        }
    }

    /// An invisible cursor over the guest's screen: the guest draws its own.
    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override func resetCursorRects() {
        // Not in Harmony: there the pointer is hidden per position (only over a
        // guest window), by cursorUpdate/keepPointerHidden, not a blanket rect.
        if mouseMode == .seamless && !harmony {
            addCursorRect(screenRect, cursor: Self.blankCursor)
        }
    }

    /// AppKit consults the cursor rects only now and then -- after a click,
    /// when the app is activated -- and puts the arrow back in between, so
    /// this Mac's pointer would appear alongside the one the guest draws.
    /// Setting it here, on every cursor update and every movement, keeps
    /// the two from showing at once.
    override func cursorUpdate(with event: NSEvent) {
        if hidesPointer(at: convert(event.locationInWindow, from: nil)) {
            Self.blankCursor.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// Whether this Mac's pointer belongs out of sight: over the guest's
    /// screen, with the guest drawing its own.
    private func hidesPointer(at p: CGPoint) -> Bool {
        // Not over the overlay: the reader needs to see what they are
        // dragging.  Not over the toolbar either: the toolbar is this Mac's,
        // and the guest's own cursor cannot be moved onto it -- it stops at
        // the top of its screen and stays there, which left the bar
        // impossible to aim at.
        // And only while the guest is actually drawing a pointer.  Mac OS X
        // 10.4 draws its own through the hardware cursor PowerEmu's NDRV
        // provides, so this Mac's has to be out of the way.  10.5's ATI
        // driver takes the card over and never uses it, so nothing is drawn
        // at all -- and hiding this Mac's pointer as well left the reader
        // clicking blind, with no way to tell where they were pointing.
        // In Harmony the guest's screen is masked to its windows, so its own
        // pointer only shows over one of them; anywhere else -- its masked-away
        // desktop -- this Mac's pointer must stay visible, or the pointer
        // vanishes between windows.
        mouseMode == .seamless && !grabbed && screenRect.contains(p)
            && !onPerf(p) && !onBar(p) && guestDrawsPointer
            && (!harmony || guestPixelOpaque(atViewPoint: p))
    }

    /// Whether the guest has given us a pointer to draw.
    private var guestDrawsPointer: Bool { cursor.contents != nil }

    /// Whether `p` is on the toolbar while it is down.
    private func onBar(_ p: CGPoint) -> Bool {
        guard let c = controls, c.shown, !c.bar.isHidden else { return false }
        return c.bar.frame.contains(p)
    }

    private func keepPointerHidden(_ e: NSEvent) {
        guard hidesPointer(at: convert(e.locationInWindow, from: nil)) else { return }
        if NSCursor.current !== Self.blankCursor { Self.blankCursor.set() }
    }

    func grab() {
        /*
         * Not in the masked desktop.  There the guest's windows sit among this
         * Mac's own, so the pointer has to stay this Mac's to command -- taking
         * it means the reader cannot reach a window of their own that is in
         * plain sight behind the guest's, and has to ask for the mouse back
         * before they can click anything at all.
         */
        guard !(harmony && maskedDesktop) else { return }
        guard mouseMode == .captured, !grabbed, window?.isKeyWindow == true else { return }
        grabbed = true
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
        flashHint(false)
    }

    func ungrab() {
        if buttons != 0 { buttons = 0; channel.send(.buttons, [0]) }
        guard grabbed else { return }
        grabbed = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    private func flashHint(_ show: Bool) {
        // Nothing to offer to give back: the masked desktop never takes it.
        if harmony && maskedDesktop { hint.isHidden = true; return }
        hint.isHidden = !show || mouseMode != .captured
    }

    override func mouseEntered(with event: NSEvent) {
        keepPointerHidden(event)
        if !grabbed { flashHint(true) }
    }
    override func mouseExited(with event: NSEvent) { flashHint(false) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .cursorUpdate,
                                                               .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// Where an event is on the guest's screen, in guest pixels (nil: off it).
    private func guestPoint(_ e: NSEvent) -> (Int32, Int32)? {
        let p = convert(e.locationInWindow, from: nil)
        let r = screenRect
        guard r.width > 0, r.height > 0, r.contains(p) else { return nil }
        let x = (p.x - r.minX) / r.width * guestSize.width
        let y = (r.maxY - p.y) / r.height * guestSize.height
        return (Int32(max(0, min(guestSize.width - 1, x))), Int32(max(0, min(guestSize.height - 1, y))))
    }

    /// Seamless: point the guest at the event; false if it's off its screen.
    @discardableResult
    private func point(_ e: NSEvent) -> Bool {
        guard mouseMode == .seamless, let (x, y) = guestPoint(e) else { return false }
        sendGuestPoint(CGPoint(x: CGFloat(x), y: CGFloat(y)))
        return true
    }

    private var engaged: Bool { mouseMode == .seamless || grabbed }

    private func button(_ bit: Int32, _ down: Bool) {
        let b = down ? buttons | bit : buttons & ~bit
        guard b != buttons else { return }
        buttons = b
        channel.send(.buttons, [b])
    }

    override func mouseDown(with e: NSEvent) {
        /*
         * A failure notice goes away on the first click, and that click is
         * spent doing it.  The status view itself cannot take the click --
         * it returns nil from hitTest so the toolbar and the guest stay
         * live underneath -- so it has to be caught here.
         */
        if dismissStatusIfAllowed() { return }
        // The overlay is the reader's, not the guest's: a click on it picks
        // it up to be dragged, and never reaches Mac OS X.
        let p = convert(e.locationInWindow, from: nil)
        if harmony && maskedDesktop {
            harmonyDebug("PEINPUT down view=\(p) guest=\(String(describing: guestPoint(e))) cursor=\(cursorPos) buttons=\(buttons)")
        }
        if onPerf(p) && !grabbed {
            perfDragFrom = CGPoint(x: p.x - perf.frame.minX, y: p.y - perf.frame.minY)
            return
        }
        /*
         * The click that takes the mouse is not passed on -- but in the masked
         * desktop the mouse is never taken, so there is no such click, and
         * treating every one as if there were swallowed all of them.  Nothing
         * reached the guest at all, which is what clicking a window and having
         * nothing happen looked like.
         */
        if !(harmony && maskedDesktop),
           mouseMode == .captured && !grabbed { grab(); return }
        if mouseMode == .seamless && !point(e) { return }
        beginHarmonyDrag(e)
        button(1, true)
    }
    override func mouseUp(with e: NSEvent) {
        if harmony && maskedDesktop { harmonyDebug("PEINPUT up guest=\(String(describing: guestPoint(e))) cursor=\(cursorPos) buttons=\(buttons)") }
        if perfDragFrom != nil {
            perfDragFrom = nil
            rememberPerfSpot()
            return
        }
        if dragLayerId != nil { endHarmonyDrag() }
        if engaged { point(e); button(1, false) }
    }
    override func rightMouseDown(with e: NSEvent) { if grabbed || point(e) { button(2, true) } }
    override func rightMouseUp(with e: NSEvent) { if engaged { point(e); button(2, false) } }
    override func otherMouseDown(with e: NSEvent) { if grabbed || point(e) { button(4, true) } }
    override func otherMouseUp(with e: NSEvent) { if engaged { point(e); button(4, false) } }

    private func move(_ e: NSEvent) {
        if !grabbed, let c = controls {
            let p = convert(e.locationInWindow, from: nil)
            c.pointerMoved(p, in: self)
            if c.shown && c.bar.frame.contains(p) { return }     // on the bar, not the guest
        }
        if mouseMode == .seamless { point(e); return }
        guard grabbed else { return }
        motion.x += e.deltaX
        motion.y += e.deltaY
        let dx = Int32(motion.x.rounded(.towardZero)), dy = Int32(motion.y.rounded(.towardZero))
        guard dx != 0 || dy != 0 else { return }
        motion.x -= CGFloat(dx); motion.y -= CGFloat(dy)
        channel.send(.motion, [dx, dy])
    }
    override func mouseMoved(with e: NSEvent) { keepPointerHidden(e); move(e) }
    override func mouseDragged(with e: NSEvent) {
        if harmony && maskedDesktop { harmonyDebug("PEINPUT drag guest=\(String(describing: guestPoint(e))) mode=\(mouseMode) buttons=\(buttons)") }
        if let from = perfDragFrom {
            let p = convert(e.locationInWindow, from: nil)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            perf.frame.origin = CGPoint(x: (p.x - from.x).rounded(), y: (p.y - from.y).rounded())
            CATransaction.commit()
            return
        }
        keepPointerHidden(e); move(e)
        updateHarmonyDrag(e)
    }
    override func rightMouseDragged(with e: NSEvent) { move(e) }
    override func otherMouseDragged(with e: NSEvent) { move(e) }

    override func scrollWheel(with e: NSEvent) {
        guard grabbed || (mouseMode == .seamless && guestPoint(e) != nil) else { return }
        // Trackpads give pixels; the guest wants wheel clicks.
        scroll += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 12 : e.scrollingDeltaY
        let lines = Int32(scroll.rounded(.towardZero))
        guard lines != 0 else { return }
        scroll -= CGFloat(lines)
        channel.send(.wheel, [lines, 0])
    }

    // MARK: the keyboard

    /// Control-Option-G / -F stay with PowerEmu; everything else, Command
    /// shortcuts included, belongs to the guest while this view has focus.
    private func isHostShortcut(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection([.control, .option, .command, .shift])
        guard f == [.control, .option] else { return false }
        switch e.keyCode {
        case 5: ungrab(); return true                                  // G
        case 3: onToggleFullScreen?(); return true                     // F
        case 35: togglePerformance(); return true                      // P
        case 4: requestHarmony(!harmony); return true                        // H
        default: return false
        }
    }

    private func key(_ code: UInt16, _ down: Bool) {
        if down { pressed.insert(code) } else { pressed.remove(code) }
        channel.send(.key, [Int32(code), down ? 1 : 0])
    }

    override func keyDown(with e: NSEvent) {
        if isHostShortcut(e) { return }
        if dismissStatusIfAllowed() { return }   /* see mouseDown */
        if e.isARepeat { return }            // the guest repeats keys itself
        syncModifiers(e.modifierFlags)
        key(e.keyCode, true)
    }

    override func keyUp(with e: NSEvent) {
        if pressed.contains(e.keyCode) { key(e.keyCode, false) }
        for c in synthesized where pressed.contains(c) { key(c, false) }
        synthesized.removeAll()
    }

    /// Make the guest's modifier keys match the event's flags.  A keyboard
    /// reports each modifier with flagsChanged first, but synthesized events
    /// (screen sharing, accessibility tools) may only carry the flag.
    private func syncModifiers(_ flags: NSEvent.ModifierFlags) {
        let mods: [(NSEvent.ModifierFlags, [UInt16])] = [(.shift, [56, 60]), (.control, [59, 62]),
                                                          (.option, [58, 61]), (.command, [55, 54])]
        for (flag, codes) in mods {
            let down = codes.contains { pressed.contains($0) }
            if flags.contains(flag) && !down { key(codes[0], true); synthesized.insert(codes[0]) }
            if !flags.contains(flag) && down { for c in codes where pressed.contains(c) { key(c, false) } }
        }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.type == .keyDown else { return super.performKeyEquivalent(with: e) }
        keyDown(with: e)
        return true
    }

    /// Modifiers arrive as flag changes; tell down from up per key.
    override func flagsChanged(with e: NSEvent) {
        let raw = e.modifierFlags.rawValue
        let sided: [UInt16: UInt] = [56: 0x2, 60: 0x4, 59: 0x1, 62: 0x2000, 58: 0x20, 61: 0x40, 55: 0x8, 54: 0x10]
        if let bit = sided[e.keyCode] {
            synthesized.remove(e.keyCode)
            key(e.keyCode, raw & bit != 0)
        } else if e.keyCode == 57 {          // Caps Lock: a press each time it changes
            key(57, true); key(57, false)
        }
    }

    /// Press keys together (in order) and let go (in reverse): for the Keys
    /// menu.  Mac virtual key codes.
    func sendCombo(_ codes: [UInt16]) {
        for c in codes { channel.send(.key, [Int32(c), 1]) }
        for c in codes.reversed() { channel.send(.key, [Int32(c), 0]) }
    }

    /// Let go of everything when the window loses focus, so nothing sticks.
    func releaseAll() {
        for k in pressed { channel.send(.key, [Int32(k), 0]) }
        pressed.removeAll(); synthesized.removeAll()
        if harmonyInputButtons != 0 {
            harmonyDebug("PEINPUT releaseAll buttons=\(harmonyInputButtons) physicalButtons=\(NSEvent.pressedMouseButtons)")
            harmonyInputButtons = 0; sendHarmonyPointer()
        }
        ungrab()
    }
}

/// One window per running virtual Mac.  Closing it only hides it: the
/// virtual Mac keeps running (Show Window brings it back).
/// The virtual Mac's window.  A borderless window (which Harmony makes it,
/// to cover this Mac's screen over its own desktop) cannot become key on its
/// own, so this says it can -- otherwise the keyboard would stop reaching the
/// guest the moment Harmony turned on.
final class VMWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class VMWindowController: NSWindowController, NSWindowDelegate {
    static var open: [URL: VMWindowController] = [:]
    /// The one the Machine menu acts on: the key window's, else the main
    /// window's, else the only one open.
    static var key: VMWindowController? {
        open.values.first { $0.window?.isKeyWindow == true }
            ?? open.values.first { $0.window?.isMainWindow == true }
            ?? (open.count == 1 ? open.values.first : nil)
    }

    let vm: VirtualMachine
    let display: VMDisplayView
    private var sizedOnce = false
    private var toolbar: VMToolbarController?

    init(vm: VirtualMachine, channel: DisplayChannel) {
        self.vm = vm
        display = VMDisplayView(channel: channel)
        let w = VMWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = vm.config.name
        w.contentView = display
        w.collectionBehavior = [.fullScreenPrimary]
        w.acceptsMouseMovedEvents = true
        w.backgroundColor = .black
        w.setFrameAutosaveName("PowerEmu VM \(vm.config.name)")
        super.init(window: w)
        w.delegate = self
        display.onToggleFullScreen = { [weak w] in w?.toggleFullScreen(nil) }
        display.onHarmonyGuest = { [weak vm] on in vm?.harmony(on) }
        /*
         * A way in for the test rig.  Harmony is a toolbar button and a warning
         * sheet, which is right for a reader and useless for measuring: there
         * is no way to time how long a window's picture stays stale without
         * being able to start the thing from a script.
         */
        if let v = ProcessInfo.processInfo.environment["POWEREMU_HARMONY_AUTO"] {
            let after = Double(v) ?? 20
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak display] in
                display?.requestHarmony(true)
            }
        }
        display.onHarmonyResolution = { [weak vm] w, h in vm?.setGuestResolution(w, h) }
        display.onHarmonyRaise = { [weak vm] id in vm?.raiseGuestWindow(id) }
        display.onHarmonyRaiseHard = { [weak vm] id in vm?.raiseGuestWindowHard(id) }
        display.onWantAppIcon = { [weak vm] pid in vm?.guestAppIcon(pid) }
        display.onDropPromises = { [weak vm] receivers, id in vm?.fileTransfer.importPromises(receivers, window: id) ?? false }
        display.onDropFiles = { [weak vm] urls, windowID in
            vm?.fileTransfer.importFiles(urls, window: windowID) ?? false
        }
        display.onDropFilesToApp = { [weak vm] urls, pid in
            vm?.fileTransfer.importFiles(urls, application: pid) ?? false
        }
        display.onArmFileDrag = { [weak vm] id, point in vm?.fileTransfer.armDrag(window: id, point: point) }
        display.onPrepareFileDrag = { [weak vm] id, done in
            guard let vm else { done([]); return }
            vm.fileTransfer.prepareDrag(window: id, completion: done)
        }
        display.onQuitGuestApp = { [weak vm] pid in vm?.quitGuestApp(pid) }
        display.onHarmonyMove = { [weak vm] id, x, y in vm?.moveGuestWindow(id, x, y) }
        display.onHarmonyRaiseAt = { [weak vm] id, x, y in vm?.raiseGuestWindowAt(id, x, y) }
        channel.onDockApps = { [weak display] items in display?.setGuestDockApps(items) }
        display.onLaunchGuestApp = { [weak vm] path in vm?.launchGuestApp(path: path) }
        VMDisplayView.showing = display
        display.machineName = vm.config.name
        display.onActivateGuestApp = { [weak vm] pid in vm?.activateGuestApp(pid) }
        display.onRestoreGuestWindow = { [weak vm] pid, i in vm?.restoreGuestWindow(pid, i) }
        display.onMinimizeGuestWindow = { [weak vm] id in vm?.minimizeGuestWindow(id) }
        display.onToolsStateQuery = { [weak vm] in String(describing: vm?.toolsState) }
        display.onHarmonyMoveDrag = { [weak vm] id, gx, gy, ex, ey in
            vm?.dragGuestWindow(id, gx, gy, ex, ey)
        }
        display.onHarmonyChanged = { [weak w, weak vm] on in
            guard let w, let vm else { return }
            w.title = on ? "\(vm.config.name) \u{2014} Harmony (in testing)" : vm.config.name
        }
        display.mouseMode = VMDisplayView.MouseMode(rawValue: vm.config.mouseMode) ?? .seamless
        display.scaling = vm.config.scaling
        display.panelFilter = vm.config.panelFilter
        display.displayFit = vm.config.displayFit
        display.overscan = vm.config.overscan
        toolbar = VMToolbarController(self)
        display.controls = toolbar
        display.addSubview(toolbar!.bar)
        // Keep the Devices badge honest about the guest's tools.
        vm.onToolsChanged = { [weak self] in self?.toolbar?.refreshToolsBadge() }
        toolbar?.refreshToolsBadge()
        display.queryPerf = { [weak vm] done in
            guard let vm else { done(nil); return }
            MainActor.assumeIsolated { vm.queryPerf(done: done) }
        }
        display.qemuPID = { [weak vm] in
            MainActor.assumeIsolated { vm?.qemuPID }
        }
        if w.frameAutosaveName.isEmpty || !w.setFrameUsingName(w.frameAutosaveName) { w.center() }
        // Open at the size the guest last had (it boots at it too).
        let boot = CGSize(width: max(640, vm.config.bootWidth), height: max(480, vm.config.bootHeight))
        display.setGuestSize(boot)
        fitWindow(boot)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func show(_ vm: VirtualMachine, channel: DisplayChannel) -> VMWindowController {
        let c = open[vm.url] ?? VMWindowController(vm: vm, channel: channel)
        open[vm.url] = c
        if c.display.harmony && !c.display.maskedDesktop {
            c.display.harmonyManager.showFrontGuestWindow()
        } else {
            c.showWindow(nil)
            c.window?.makeFirstResponder(c.display)
        }
        return c
    }

    static func close(_ vm: VirtualMachine) {
        guard let c = open.removeValue(forKey: vm.url) else { return }
        c.display.releaseAll()
        c.window?.orderOut(nil)
        c.window?.close()
    }

    /// The guest changed resolution: fit the window to it (1:1 when there's
    /// room), and remember it so the next boot starts at this size.
    func guestResized(_ size: CGSize) {
        let w = Int(size.width), h = Int(size.height)
        if !display.isHarmonyDisplayTransition && w >= 800 && h >= 600 && (w != vm.config.bootWidth || h != vm.config.bootHeight) {
            vm.config.bootWidth = w
            vm.config.bootHeight = h
            try? vm.save()
        }
        fitWindow(size)
    }

    private func fitWindow(_ size: CGSize) {
        guard let w = window, !w.styleMask.contains(.fullScreen), let screen = w.screen ?? NSScreen.main else { return }
        let avail = screen.visibleFrame.size
        let chrome = w.frame.height - w.contentLayoutRect.height
        let scale = min(1, (avail.width) / size.width, (avail.height - chrome) / size.height)
        let content = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        w.contentAspectRatio = size
        var f = w.frameRect(forContentRect: CGRect(origin: .zero, size: content))
        f.origin = CGPoint(x: w.frame.midX - f.width / 2, y: w.frame.maxY - f.height)
        f.origin.x = max(screen.visibleFrame.minX, min(f.origin.x, screen.visibleFrame.maxX - f.width))
        f.origin.y = max(screen.visibleFrame.minY, min(f.origin.y, screen.visibleFrame.maxY - f.height))
        w.setFrame(f, display: true, animate: sizedOnce)
        sizedOnce = true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        display.releaseAll()
        sender.orderOut(nil)                  // keeps running; Show Window brings it back
        return false
    }

    /// Full screen belongs to the virtual Mac.  By default macOS keeps its
    /// own menu bar on the same edge, dropping it over the top whenever the
    /// pointer goes up there -- which is exactly the movement that brings
    /// PowerEmu's toolbar down, so the two arrived together and the toolbar
    /// had to sit underneath, out of reach.  Hiding the menu bar gives the
    /// top edge to the toolbar.  Control-Option-F leaves full screen, and
    /// the toolbar's own Full Screen button does the same.
    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        [.fullScreen, .hideDock, .hideMenuBar]
    }

    func windowDidResignKey(_ n: Notification) { display.releaseAll() }
    /*
     * Harmony and full screen cannot both own the screen.
     *
     * requestHarmony() already refuses to start Harmony while the window is
     * full screen -- it leaves full screen, waits, and tries again.  The
     * reverse was not guarded at all, so going full screen with Harmony on
     * gave a black screen: in Harmony the guest's desktop is masked and its
     * windows are drawn as windows of this Mac, so the view itself has
     * nothing left to show, and with the ordinary guest window gone there was
     * no way back to it.
     *
     * Drop Harmony first, the mirror of what starting it does.  This is on
     * the window delegate rather than the toolbar's handler so it covers
     * every route in: the F key, the green button, and View > Enter Full
     * Screen.
     */
    func windowWillEnterFullScreen(_ n: Notification) {
        if display.harmony { display.requestHarmony(false) }
    }

    func windowDidEnterFullScreen(_ n: Notification) { display.needsLayout = true }

    /*
     * Give this Mac its menu bar back.
     *
     * The options above are meant to belong to the full screen session and
     * to lapse with it, but the hidden menu bar outlived it: leaving full
     * screen gave back the window and left the top of this Mac's screen
     * black, with menus that still dropped down when clicked but could not
     * be read.  Saying plainly that nothing is hidden any more is what
     * actually restores it.
     */
    private func restorePresentation() {
        if !NSApp.presentationOptions.isEmpty { NSApp.presentationOptions = [] }
    }

    func windowWillExitFullScreen(_ n: Notification) { restorePresentation() }
    func windowDidExitFullScreen(_ n: Notification) {
        display.needsLayout = true
        restorePresentation()
    }
    func windowWillClose(_ n: Notification) { restorePresentation() }
}
