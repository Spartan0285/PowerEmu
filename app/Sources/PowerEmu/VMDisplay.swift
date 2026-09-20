import AppKit
import IOSurface
import QuartzCore

/// The virtual Mac's screen inside PowerEmu (instead of QEMU's own window).
///
/// QEMU's poweremu-display object (poweremu-qemu: ui/poweremu-display.c)
/// connects to a Unix socket PowerEmu listens on.  It passes the guest's
/// screen as shared memory (its fd with SCM_RIGHTS) and then only says which
/// rectangle changed; PowerEmu copies each changed frame into one of two
/// IOSurfaces and hands that to Core Animation.  Keyboard and mouse go back
/// the same way.  Messages: { u32 type, u32 length } + payload; see the QEMU
/// file for the list.
final class DisplayChannel: @unchecked Sendable {
    enum Kind: UInt32 { case surface = 1, damage = 2, cursor = 3, mouse = 4, key = 10, motion = 11, buttons = 12, wheel = 13, point = 14 }

    let socketPath: String
    /// Called on the main thread.
    var onFrame: ((IOSurfaceRef, Int, Int) -> Void)?
    var onCursor: ((CGImage?, Int, Int) -> Void)?          // image, hot spot
    var onMouse: ((Int, Int, Bool) -> Void)?
    var onDisconnect: (() -> Void)?

    private var listenFD: Int32 = -1
    private var fd: Int32 = -1
    private let writeLock = NSLock()

    // The shared frame from QEMU and our two copies of it.
    private var shm: UnsafeMutableRawPointer?
    private var shmSize = 0
    private var width = 0, height = 0, stride = 0
    private var surfaces: [IOSurfaceRef] = []
    private var back = 0
    private let pendingLock = NSLock()
    private var pending = false            // a frame is waiting for the main thread
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
            present()
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
        surfaces = (0..<2).compactMap { _ in IOSurfaceCreate(props as CFDictionary) }
        back = 0
        present()
    }

    /// Copy QEMU's frame into the back surface and show it.  While the main
    /// thread hasn't shown the last one yet, keep refreshing that one instead.
    private func present() {
        guard let shm, surfaces.count == 2 else { return }
        pendingLock.lock()
        let target = pending ? 1 - back : back
        let s = surfaces[target]
        IOSurfaceLock(s, [], nil)
        let dst = IOSurfaceGetBaseAddress(s), bpr = IOSurfaceGetBytesPerRow(s)
        if bpr == stride {
            memcpy(dst, shm, stride * height)
        } else {
            for y in 0..<height { memcpy(dst + y * bpr, shm + y * stride, width * 4) }
        }
        IOSurfaceUnlock(s, [], nil)
        let first = !pending
        if first { pending = true; back = 1 - back }
        pendingLock.unlock()
        guard first else { return }
        let w = width, h = height
        DispatchQueue.main.async {
            self.pendingLock.lock(); self.pending = false; self.pendingLock.unlock()
            self.framesShown += 1
            self.onFrame?(s, w, h)
        }
    }
}

/// Shows the frames, draws the guest's hardware cursor, and turns keyboard
/// and mouse events into input for the guest.
final class VMDisplayView: NSView {
    let channel: DisplayChannel
    var onToggleFullScreen: (() -> Void)?
    /// The control bar floating over the top of the screen.
    weak var controls: VMToolbarController?
    private let screen = CALayer()
    private let cursor = CALayer()
    private let hint = CATextLayer()
    private let perf = CATextLayer()
    private var perfTimer: Timer?
    private var lastPerf: (time: TimeInterval, frames: Double, draws: Double, shown: Int,
                           texVRAM: Double, texAGP: Double, agpBytes: Double)?
    /// Asks the GPU model for its totals ("frames=… draws=…").
    var queryPerf: ((@escaping @Sendable (String?) -> Void) -> Void)?
    /// The emulator's pid, for the overlay's host-side figures.
    var qemuPID: (() -> pid_t?)?
    private let hostStats = HostStats()
    var showsPerformance: Bool { perfTimer != nil }
    private(set) var guestSize = CGSize(width: 1024, height: 768)
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

    init(channel: DisplayChannel) {
        self.channel = channel
        super.init(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        screen.contentsGravity = .resize
        screen.isOpaque = true
        screen.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        cursor.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        cursor.anchorPoint = .zero
        cursor.isHidden = true
        cursor.magnificationFilter = .nearest
        layer?.addSublayer(screen)
        screen.addSublayer(cursor)
        hint.string = "Click to use the mouse in the virtual Mac.  Control-Option-G gives it back."
        hint.fontSize = 12
        hint.alignmentMode = .center
        hint.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        hint.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        hint.cornerRadius = 6
        hint.isHidden = true
        layer?.addSublayer(hint)
        perf.fontSize = 11
        perf.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        perf.foregroundColor = NSColor.white.cgColor
        perf.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        perf.cornerRadius = 6
        perf.isWrapped = true
        perf.isHidden = true
        perf.contentsScale = 2
        perf.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(perf)

        channel.onFrame = { [weak self] s, w, h in self?.show(s, w, h) }
        channel.onCursor = { [weak self] img, hx, hy in self?.setCursor(img, hx, hy) }
        channel.onMouse = { [weak self] x, y, on in
            self?.cursorPos = CGPoint(x: x, y: y); self?.cursorOn = on; self?.placeCursor()
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

    private func show(_ s: IOSurfaceRef, _ w: Int, _ h: Int) {
        let size = CGSize(width: w, height: h)
        if size != guestSize {
            guestSize = size
            (window?.windowController as? VMWindowController)?.guestResized(size)
            needsLayout = true
        }
        screen.contents = s
    }

    /// The guest's screen, as large as fits (below the notch in fullscreen),
    /// in whole multiples when it fits that way so pixels stay sharp.
    var screenRect: CGRect {
        let i = safeAreaInsets
        let area = CGRect(x: bounds.minX + i.left, y: bounds.minY + i.bottom,
                          width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom)
        guard guestSize.width > 0, guestSize.height > 0 else { return area }
        var scale = min(area.width / guestSize.width, area.height / guestSize.height)
        if scale > 1 && scale < 1.1 { scale = 1 }       // a little border beats a blurry screen
        let w = (guestSize.width * scale).rounded(), h = (guestSize.height * scale).rounded()
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h).integral
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        screen.frame = screenRect
        let exact = screen.frame.width == guestSize.width
        screen.magnificationFilter = exact ? .nearest : .linear
        screen.minificationFilter = .linear
        let hs = CGSize(width: 480, height: 22)
        hint.frame = CGRect(x: bounds.midX - hs.width / 2, y: 16, width: hs.width, height: hs.height)
        let sr = screenRect
        layoutPerf()
        if let bar = controls?.bar {
            // Over the screen, never beside it; below the menu bar in full screen.
            let size = bar.fittingBarSize
            let menuBar = window?.styleMask.contains(.fullScreen) == true ? (NSApp.mainMenu?.menuBarHeight ?? 24) : 0
            bar.frame = CGRect(x: (bounds.midX - size.width / 2).rounded(),
                               y: (bounds.maxY - size.height - 8 - menuBar).rounded(),
                               width: size.width, height: size.height)
        }
        CATransaction.commit()
        placeCursor()
        window?.invalidateCursorRects(for: self)
    }

    private func setCursor(_ img: CGImage?, _ hx: Int, _ hy: Int) {
        cursor.contents = img
        cursorSize = img.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        cursorHot = CGPoint(x: hx, y: hy)
        placeCursor()
    }

    /// Guest pixels (origin top left) to the screen layer (origin bottom left).
    private func placeCursor() {
        let scale = guestSize.width > 0 ? screen.bounds.width / guestSize.width : 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cursor.bounds = CGRect(origin: .zero, size: CGSize(width: cursorSize.width * scale, height: cursorSize.height * scale))
        let x = (cursorPos.x - cursorHot.x) * scale
        let top = (cursorPos.y - cursorHot.y) * scale
        cursor.position = CGPoint(x: x, y: screen.bounds.height - top - cursorSize.height * scale)
        cursor.isHidden = !cursorOn || cursor.contents == nil
        CATransaction.commit()
    }

    // MARK: the performance overlay

    func togglePerformance() {
        if let t = perfTimer {
            t.invalidate(); perfTimer = nil; perf.isHidden = true; lastPerf = nil
            return
        }
        perf.string = " Measuring…"
        perf.isHidden = false
        needsLayout = true
        samplePerformance()
        perfTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePerformance() }
        }
    }

    /// Size the overlay to whatever it currently says.
    ///
    /// It used to be a fixed 330x62, which fitted the three lines it had at
    /// the time and silently clipped the fourth when one was added. Measuring
    /// the text means a line can be added or reworded without anyone having to
    /// remember to re-measure a constant.
    private func layoutPerf() {
        let text = (perf.string as? String) ?? ""
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: 4000, height: 4000),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font])
        let w = max(330, ceil(measured.width) + 18)
        let h = max(24, ceil(measured.height) + 10)
        let sr = screenRect
        perf.frame = CGRect(x: sr.minX + 10, y: sr.maxY - 10 - h, width: w, height: h)
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
        let warn = h.contended ? "  << STARVED: something else has the CPU" :
            (h.thermal == .nominal ? "" : "  << THERMAL \(h.thermalText)")

        perf.string = String(format: " Guest %4.0f fps   window %3.0f fps   %5.0f draws/s\n"
                                   + " VRAM peak %5.1f of %.0f MB\n"
                                   + " Textures from AGP %3.0f%%   (%.1f MB/s copied)\n"
                                   + " Host %3.0f%% busy   emulator %3.0f%%   load %.1f/%d   thermal %@%@",
                             fps, shownRate, draws, (v["vram_high"] ?? 0) / mb, (v["vram_usable"] ?? 0) / mb,
                             agpShare, agpMB,
                             h.hostBusy, h.qemuCPU, h.load1, h.cores,
                             h.thermalText as NSString, warn as NSString)
        layoutPerf()
    }

    // MARK: the mouse

    /// Seamless: the pointer moves in and out of the virtual Mac freely (a
    /// USB tablet in the guest takes absolute positions).  Captured: a click
    /// takes the mouse and sends raw movement, for games that turn the view
    /// with it; Control-Option-G gives it back.
    enum MouseMode: String { case seamless, captured }

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
        if mouseMode == .seamless {
            addCursorRect(screenRect, cursor: Self.blankCursor)
        }
    }

    func grab() {
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
        hint.isHidden = !show || mouseMode != .captured
    }

    override func mouseEntered(with event: NSEvent) { if !grabbed { flashHint(true) } }
    override func mouseExited(with event: NSEvent) { flashHint(false) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
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
        channel.send(.point, [x, y])
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
        if mouseMode == .captured && !grabbed { grab(); return }   // the capturing click isn't passed on
        if mouseMode == .seamless && !point(e) { return }
        button(1, true)
    }
    override func mouseUp(with e: NSEvent) { if engaged { point(e); button(1, false) } }
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
    override func mouseMoved(with e: NSEvent) { move(e) }
    override func mouseDragged(with e: NSEvent) { move(e) }
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
        default: return false
        }
    }

    private func key(_ code: UInt16, _ down: Bool) {
        if down { pressed.insert(code) } else { pressed.remove(code) }
        channel.send(.key, [Int32(code), down ? 1 : 0])
    }

    override func keyDown(with e: NSEvent) {
        if isHostShortcut(e) { return }
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
        pressed.removeAll()
        ungrab()
    }
}

/// One window per running virtual Mac.  Closing it only hides it: the
/// virtual Mac keeps running (Show Window brings it back).
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
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
        display.mouseMode = VMDisplayView.MouseMode(rawValue: vm.config.mouseMode) ?? .seamless
        toolbar = VMToolbarController(self)
        display.controls = toolbar
        display.addSubview(toolbar!.bar)
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
        c.showWindow(nil)
        c.window?.makeFirstResponder(c.display)
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
        if w >= 800 && h >= 600 && (w != vm.config.bootWidth || h != vm.config.bootHeight) {
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

    func windowDidResignKey(_ n: Notification) { display.releaseAll() }
    func windowDidEnterFullScreen(_ n: Notification) { display.needsLayout = true }
    func windowDidExitFullScreen(_ n: Notification) { display.needsLayout = true }
}
