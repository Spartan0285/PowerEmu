import Foundation
import AppKit
import DiskArbitration

/// Starts the bundled QEMU for one virtual Mac and talks to it over QMP.
///
/// The command line mirrors launcher/launch-tiger-ati.sh, which is where each
/// option is explained; keep the two in step.
@MainActor
final class VMRunner {
    /// The lowest processor speed Mac OS X is told (see the boot command).
    static let minReportedMHz = 1420
    private let vm: VirtualMachine
    private var process: Process?
    /// When an external disk is lent, QEMU is started with posix_spawn so the
    /// disk's open file descriptor can be handed down (Foundation's Process
    /// drops inherited fds).  These track that child and the fd to give back.
    // QEMU's macOS host_device driver opens the device read-only first (to
    // check it is not mounted) and then read-write, and it matches an fdset fd
    // by exact access mode, so the set must hold both an O_RDONLY and an
    // O_RDWR fd.  These are their fixed numbers inside the child.
    static let externalReadFD: Int32 = 20         // O_RDONLY, for the mount check
    static let externalWriteFD: Int32 = 21        // O_RDWR, for the disk itself
    static let externalFDSet = 7                  // the fdset id both belong to
    private var spawnPID: pid_t = 0
    private var externalFDs: [Int32] = []         // host-side fds to close on stop
    private var externalExitSource: DispatchSourceProcess?
    private var externalBSD: String?              // host disk to give back on stop
    /// Watches an adopted machine (one this PowerEmu did not start).
    private var adoptWatch: Timer?
    private var qmpPath: String
    /// PowerEmu Tools' socket (GuestAgent listens on it).
    private(set) var agentPath: String
    /// Shared folders' WebDAV socket (WebDAVServer listens on it).
    private(set) var davPath: String
    /// PowerEmu Clock's socket (ClockServer listens on it).
    private(set) var clockPath: String
    /// The screen's socket (DisplayChannel listens on it) when shown in PowerEmu.
    private(set) var displayPath: String
    /// The second screen's socket, when the machine has two.
    private(set) var displayPath2: String
    /// The game controller's socket (GamepadServer listens on it).
    private(set) var gamepadPath: String
    /// Services of the guest offered to the network: guest service to the
    /// port this Mac listens on. Empty unless the reader shares them.
    var sharedPorts: [NetworkShare.Service: Int] = [:]
    /// Option B: the Unix socket PowerEmu listens on to bridge the guest's
    /// burn to a physical drive.  Set before start when a physical burn is armed.
    var burnStreamSocket: String?
    /// Where the network helper and the emulator meet, when the guest is
    /// bridged straight on to this Mac's network.
    private(set) var bridgeHelperPath: String
    private(set) var bridgeEmulatorPath: String
    /// The address the network gave the bridge, for the guest's own card.
    var bridgeMAC: String?
    /// The host ports this run uses: the configured ones, or the next free
    /// ones when another virtual Mac (or anything else) has them.
    private(set) var sshPort: Int?
    private(set) var monitorPort: Int?
    /// An unattended run (installing): no screen, and a guest restart ends
    /// the emulator instead of restarting, which is how an install says done.
    var headless = false
    /// Start from the memory saved when the machine was put to sleep,
    /// rather than from the beginning.
    var wake = false
    /// What the saved machine is called inside the disk.
    static let sleepTag = "PowerEmuSleep"

    init(vm: VirtualMachine) {
        self.vm = vm
        // Unix socket paths are limited to 104 bytes; keep it short. The
        // name must be the same in every PowerEmu that ever runs this
        // machine -- that is how one finds a machine another left running
        // -- so it can't come from Swift's hashValue, which is seeded anew
        // in each process.
        let tag = "poweremu-\(Self.tag(for: vm.url.path))"
        qmpPath = NSTemporaryDirectory() + tag + ".qmp"
        agentPath = NSTemporaryDirectory() + tag + ".agent"
        davPath = NSTemporaryDirectory() + tag + ".dav"
        clockPath = NSTemporaryDirectory() + tag + ".clock"
        displayPath = NSTemporaryDirectory() + tag + ".display"
        displayPath2 = NSTemporaryDirectory() + tag + ".display2"
        gamepadPath = NSTemporaryDirectory() + tag + ".pad"
        bridgeHelperPath = NSTemporaryDirectory() + tag + ".net-helper"
        bridgeEmulatorPath = NSTemporaryDirectory() + tag + ".net-guest"
    }

    /// A short, steady name for a machine's sockets: FNV-1a of its path.
    nonisolated static func tag(for path: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in path.utf8 {
            h ^= UInt64(b)
            h &*= 0x0000_0100_0000_01B3
        }
        return String(h % 1_000_000_000, radix: 36)
    }

    /// The first port from `start` that nothing on 127.0.0.1 is using.
    nonisolated static func freePort(from start: Int) -> Int { freePort(from: start, avoiding: nil) }

    nonisolated static func freePort(from start: Int, avoiding other: Int?) -> Int {
        for p in start..<(start + 100) where p != other && p <= 65535 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return start }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(p).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if r == 0 { return p }
        }
        return start
    }

    /// The helper app holding QEMU, its libraries and firmware.
    static var helperURL: URL? {
        let fm = FileManager.default
        var candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PowerEmu VM.app"),
        ]
        if let env = ProcessInfo.processInfo.environment["POWEREMU_HELPER"] {
            candidates.insert(URL(fileURLWithPath: env), at: 0)
        }
        // Running from the repository (swift run): ../build/PowerEmu VM.app
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/PowerEmu VM.app"))
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/qemu-system-ppc").path) }
    }

    func arguments(firmware fw: URL) throws -> [String] {
        let c = vm.config
        // Experimental application bundles can select the R350 device without
        // adding an unfinished Radeon 9800 choice to users' saved VM configs.
        // Normal PowerEmu bundles omit this key and continue to use the 9200.
        let r350Experiment = Bundle.main.object(forInfoDictionaryKey: "PERadeon9800Experiment") as? Bool == true
        let capabilities = SMPCapabilities.load(helper: Self.helperURL)
        let cpuArguments = try CPUOptions.arguments(count: c.cpuCount, smpCapable: capabilities != nil)
        // A machine normally boots an internal disk, but one set up to install
        // onto (or boot from) a lent external disk may have no internal disk
        // at all -- the external is its only hard disk.
        let boot = c.startupDiskConfig
        guard boot != nil || c.externalDisk != nil else { throw PackageError.missing("A startup disk") }

        // OpenBIOS: fake AGP properties on the PCI path (only used when the
        // AGP bridge is off) and the VRAM size for the QEMU VGA node.
        /*
         * Two cards have to fit in one aperture.
         *
         * The UniNorth window this machine exposes is 1 GB at 0x80000000,
         * and a card's video memory is mapped there in one naturally
         * aligned piece with its registers after it.  Two cards of 256 MB
         * push the second card's registers to 0xc0000000 -- past the end of
         * the window -- and Mac OS X panics the moment it reads them.
         * Measured: 64 and 128 MB a card both land inside, 256 does not.
         */
        let twoCardCap = 128
        var vram = c.bootFromDisc ? min(c.vramMB, 64) : c.vramMB
        if c.displays > 1 && !c.classic && !headless {
            vram = min(vram, twoCardCap)
        }
        let vramHex = String(vram * 1024 * 1024, radix: 16)
        // Match the emulator's 1 GB UniNorth PCI aperture. The SMP firmware
        // still advertises only 256 MB; with >=128 MB VRAM, GPU registers and
        // Ethernet land beyond that range and Leopard cannot attach them.
        // Two ranges, each with PCI address (3), parent address (1), size (2)
        // cells: preserve the 8 MB I/O range and expose 0x80000000–0xbfffffff.
        let pciRanges = #"" /pci@f2000000" find-device h# 1000000 encode-int h# 0 encode-int encode+ h# 0 encode-int encode+ h# f2000000 encode-int encode+ h# 0 encode-int encode+ h# 800000 encode-int encode+ h# 2000000 encode-int encode+ h# 0 encode-int encode+ h# 80000000 encode-int encode+ h# 80000000 encode-int encode+ h# 0 encode-int encode+ h# 40000000 encode-int encode+ " ranges" property device-end "#
        // The processor speed Mac OS X reports is the cpu node's
        // clock-frequency. Programs read it too, and games refuse to run
        // below their minimum (Halo on a 500 MHz "Cube"), so a chosen speed
        // is only ever raised to, never lowered below, 1.42 GHz -- the
        // fastest Power Mac G4. About This Mac shows the chosen speed anyway
        // (PEPersonalize patches its text).
        let cpuSpeed = c.cpuMHz.map { #"" /cpus/PowerPC,G4@0" find-device d# "# + String(max($0, Self.minReportedMHz) * 1_000_000) + #" encode-int " clock-frequency" property device-end "# } ?? ""
        /*
         * Classic Mac OS: take the sound hardware out of the device tree.
         *
         * macio always instantiates an AWACS "Screamer" and the firmware
         * publishes davbus/sound for it.  Mac OS 9 finds that, loads Apple
         * Audio Extension, pokes the device and dies at startup with an
         * address error -- the device answers Mac OS X's driver, not this
         * one.  There is no switch on the device and no way to leave it out,
         * so its identifying properties are deleted before the system boots
         * and nothing claims it.  Guarded, so a machine without the node
         * still boots.  Mac OS X keeps its sound; this costs a classic guest
         * audio until the device itself is taught Mac OS 9's driver.
         */
        /*
         * poweremu-audio needs no device-tree node from here.
         *
         * It used to be a macio child, published by hand from this
         * boot-command with an AAPL,address at 0x80017000, and Mac OS 9
         * never loaded a driver for it: Mac OS reads
         * driver,AAPL,MacOS,PowerPC for devices its PCI enumeration
         * discovers, and an on-board macio child is not one of those.  The
         * device is PCI now, so the firmware names the node itself after
         * the IDs -- pci1b36,5045 -- which is what the driver matches on,
         * and the loader below puts the driver on it.
         */

        let soundOff = c.classic ? #"" /pci@f2000000/mac-io@c/davbus@14000" ['] find-device catch 0= if " device_type" delete-property " compatible" delete-property " AAPL,clock-id" delete-property device-end then " /pci@f2000000/mac-io@c/davbus@14000/sound" ['] find-device catch 0= if " sound-objects" delete-property " model" delete-property device-end then "# : ""
        /*
         * What a secondary CPU needs before Mac OS will start it.
         *
         * The firmware publishes a node per CPU with reg and state, which
         * is enough for the guest to see them and not enough for it to
         * release any: on a KeyLargo machine a CPU is held in soft reset
         * through a GPIO, and the node has to say which one.  The offsets
         * are KL_GPIO_RESET_CPU0..3 -- 0x5b, 0x5c, 0x67, 0x68 -- matching
         * hw/misc/macio/gpio.c, and timebase-enable is the GPIO that lets
         * a released CPU's timebase run.
         *
         * Published from here for the same reason as everything else in
         * this boot-command: the firmware we ship is a prebuilt binary.
         * The GPIO node's phandle is read at run time rather than guessed
         * -- it is a node address and moves between boots.
         */
        let smpProps: String = {
            guard c.cpuCount > 1 else { return "" }
            let reset = ["5b", "5c", "67", "68"]
            var f = #"dev /pci@f2000000/mac-io@c/gpio@50 active-package device-end "#
            for i in 1..<min(c.cpuCount, reset.count) {
                f += #"dev /cpus/PowerPC,G4@\#(i) dup encode-int " gpio-parent" property "#
                f += #"" off" encode-string " state" property "#
                f += #"h# \#(reset[i]) encode-int " soft-reset" property "#
                f += #"1 encode-int " gpio-mask" property "#
                f += #"1 encode-int " gpio-value" property "#
                f += #"h# 73 encode-int " timebase-enable" property device-end "#
            }
            return f + "drop "
        }()

        let bootCmd = #"boot-command="# + cpuSpeed + pciRanges + smpProps + #"" /pci@f2000000" find-device " uni-north" encode-string " compatible" property device-end " /pci@f2000000/ATY,Adagio@e" ['] find-device catch 0= if 7 encode-int " IOAGPFlags" property h# 104 encode-int " IOAGPCommandValue" property device-end then " /pci@f2000000/QEMU,VGA@e" ['] find-device catch 0= if h# "# + vramHex + #" encode-int " VRAM,totalsize" property device-end then "# + soundOff + (c.classic ? #"init-program go"# : #"boot"#)

        var a: [String] = [
            "-name", c.name,
            "-L", fw.path, "-nodefaults", "-vga", "none",
            "-machine", "mac99,via=pmu",
            "-g", "\(max(640, c.bootWidth))x\(max(480, c.bootHeight))x32",
            "-device", "loader,addr=0x4000000,file=\(fw.appendingPathComponent(c.classic ? "ppc-peaudio-loader" : "ppc-ndrvloader").path)",
            "-m", String(c.effectiveMemoryMB),
            "-audio", c.audio,
        ]
        a += ["-prom-env", bootCmd]
        a += cpuArguments
        if c.extraDisplayModes {
            let gpuType = r350Experiment ? "ppc-mac-r350-probe" : "ppc-mac-gpu"
            a += ["-global", "\(gpuType).host-aspect-modes=on"]
        }
        if !c.verboseBoot {
            // Open Firmware's messages go to the serial log, not the screen:
            // it stays black until the loader draws the gray Apple.
            a += ["-prom-env", "output-device=ttya"]
        }
        if headless {
            a += ["-display", "none", "-no-reboot"]
        } else if c.embeddedDisplay {
            // No window of QEMU's own (and so no second app in the Dock).
            a += ["-display", "none", "-object", "poweremu-display,id=pd0,path=\(displayPath)"]
            // A second screen is a second card, and each card's screen needs
            // its own listener: index picks which one this object shows.
            // This has to be exactly the condition that adds the second
            // card below: a listener for a console that was never created
            // fails realize with "the machine has no screen 1".
            if c.displays > 1 && !c.classic {
                a += ["-object",
                      "poweremu-display,id=pd1,index=1,path=\(displayPath2)"]
            }
        } else {
            a += ["-display", "cocoa"]
            if c.startFullscreen { a.append("-full-screen") }
        }

        // No romfile or biosrom: the NDRV comes from ppc-ndrvloader above and
        // the kext binds on the PCI ID. See the note in VMConfig.
        //
        // While installing, cap the card at 64 MB. The Mac OS X 10.4
        // installer hangs with more -- it boots all the way to the point of
        // showing its Language Chooser, then waits forever with the Apple
        // logo on screen, which reads as a freeze at the logo but is not.
        // Measured: 128 MB hangs with the AGP bridge on or off and with or
        // without the ATI ROMs; 64 MB reaches the Language Chooser. An
        // installed system requires matching emulator/firmware PCI ranges
        // (configured above). This conservative installer cap only applies
        // while booting from the install disc and the machine keeps whatever
        // the reader chose for afterwards.
        var gpu = r350Experiment
            ? "ppc-mac-r350-probe,id=gpu0,vgamem_mb=\(vram),x-r350-bridge-aic=on,x-r350-linear-render=on"
            : "ppc-mac-gpu,id=gpu0,vgamem_mb=\(vram)"
        /*
         * Classic Mac OS draws through qemu_vga.ndrv, which reports an
         * unrounded row length to QuickDraw, while Mac OS X's ATI drivers all
         * round rowBytes up to 256 bytes and the card is seeded to match them.
         * Where the two differ -- any width that is not a multiple of 64 at
         * 32bpp, so 800 and 1440 but not 1024 or 1280 -- the screen shears
         * into diagonal bands.  Measured on Mac OS 9.2.2 at 1440x900: the
         * card scanned out 5888 bytes a row where QuickDraw drew 5760.
         */
        if c.classic { gpu += ",exact-scanout-pitch=on" }
        /*
         * And so does the first card once there are two of them.
         *
         * With one card Mac OS X's ATI driver owns the screen and paints at
         * its own 256-byte-aligned rowBytes, which is what the card is seeded
         * to scan out, and the two agree.  With two cards neither is painted
         * that way -- both are driven by qemu_vga.ndrv at the unrounded row
         * length -- so the first card shears exactly like the second did.
         * Measured at 1680x1050: scan-out 6912, content 6720, and the first
         * screen came up in diagonal bands while the second, which had the
         * flag, was clean.
         */
        if c.displays > 1 && !c.classic { gpu += ",exact-scanout-pitch=on" }
        // Bake this Mac's exact screen size (in points) into the card's EDID, so
        // Harmony can switch the guest to a mode that maps 1 guest pixel to 1
        // host point (scale 1.0).  The CRTC only encodes 8-px-aligned widths, so
        // the device snaps the scanned-out width back to this exact value.
        if let scr = NSScreen.main {
            gpu += ",host-native-width=\(Int(scr.frame.width.rounded()))"
            gpu += ",host-native-height=\(Int(scr.frame.height.rounded()))"
        }
        a += ["-device", gpu]
        /*
         * A second screen is a second graphics card.
         *
         * Mac OS X does the rest by itself: it binds its ATI driver to both
         * cards and extends the desktop across them, menu bar on the first
         * and the second standing to its right -- which is what a Power Mac
         * with two cards in it did.  Nothing here drives a second head on
         * one card, because nothing has to.
         *
         * The second card is plainer than the first in one way -- no
         * host-native EDID, because Harmony is a one-screen idea and runs on
         * the first -- but it does take exact-scanout-pitch.  That flag is
         * not about classic Mac OS as such; its precondition is "this frame
         * buffer is painted by qemu_vga.ndrv at an unrounded row length",
         * and that is the second card's situation under Mac OS X too, since
         * nothing accelerates it.  See the note on the device below.
         */
        if c.displays > 1 && !c.classic && !headless {
            /*
             * Plainer than the first card on purpose.  The host-native EDID
             * exists so Harmony can map one guest pixel to one host point,
             * and Harmony runs on the first screen; giving the second card
             * a native size the guest then does not pick leaves the EDID
             * and the mode disagreeing for no gain.
             */
            /*
             * The second card scans out the row length its frame buffer
             * really has, and does not learn one from blits.
             *
             * Both flags are needed, and they fix two different writers of
             * the scan-out stride:
             *
             *   exact-scanout-pitch=on -- the card is seeded, and its VBE
             *     mode set re-seeds it, with rowBytes rounded up to 256
             *     bytes, because that is what Mac OS X's ATI drivers do.
             *     Nothing accelerates the second card: its picture is
             *     painted by qemu_vga.ndrv at the unrounded row length, the
             *     same mismatch this flag exists for under classic Mac OS.
             *     At 1680 wide the card scanned out 6912 bytes a row where
             *     the NDRV drew 6720, and the screen sheared into diagonal
             *     bands -- 1050 x 6720 / 6912 = 1020.8, which is why the
             *     bottom 29 rows came up black.
             *
             *   present-pitch-override=off -- the card Mac OS X accelerates
             *     adopts the pitch of the compositor's blits, which is right
             *     there, because those blits are the frame.  On this card one
             *     stray blit was enough to latch a different row length onto
             *     the scan-out and shear everything after it, and a learned
             *     pitch outranks the exact one.
             */
            /*
             * The second card: a device id no ATI kext lists, and no AGP.
             *
             * `agp=off` is the one that matters.  A real Power Mac has a
             * single AGP slot behind a single UniNorth GART, so only one
             * card can be the AGP one; the device used to hand the
             * capability to every card, and IOPCIFamily then built a second
             * IOAGPDevice nub that AppleMacRiscAGP has no second GART for.
             * Two-card boots panicked or hung.  Measured with this flag and
             * nothing else changed: 5 desktops out of 5 boots, no panic in
             * any console log, against 0 out of 3 before it.
             *
             * The panic backtraces were read wrong for most of a day.  They
             * name ATIRadeon8500 under "kernel loadable modules in
             * backtrace", but that section lists every kext appearing
             * anywhere in the trace; decoding the frames against the printed
             * load addresses puts the faulting PC inside AppleMacRiscPCI,
             * with the ATI frames as its callers.
             *
             * 0x5964 stays because the accelerator should not attach to a
             * card it cannot drive, and the id has to be in OpenBIOS's
             * vga_devices[] or the card gets no display node at all -- no
             * device_type, no linebytes, no mode.  See
             * docs/BUILDING-OPENBIOS.md.
             */
            var gpu2 = (r350Experiment
                ? "ppc-mac-r350-probe,id=gpu1,vgamem_mb=\(vram)"
                : "ppc-mac-gpu,id=gpu1,vgamem_mb=\(vram)")
                + ",x-pci-device-id=0x5964,agp=off"
                + ",exact-scanout-pitch=on,present-pitch-override=off"
            /*
             * Bake the second screen's size into the second card's EDID.
             *
             * Without this the setting was decorative: it sized the host
             * window and reached neither QEMU nor the firmware, so both
             * cards advertised the first card's mode and the guest had
             * nothing else to pick in Displays.  The boot mode is still the
             * machine-wide -g for both cards -- Open Firmware keeps one
             * video_info and re-initialises it per card -- so the second
             * screen comes up at the first's size and the reader chooses
             * this one afterwards.
             */
            let w2 = max(640, c.display2Width), h2 = max(480, c.display2Height)
            gpu2 += ",host-native-width=\(w2),host-native-height=\(h2)"
            a += ["-device", gpu2]
        }
        /*
         * The paravirtual sound device, for classic guests only.
         *
         * Mac OS X drives the AWACS screamer perfectly well and has no
         * driver for this one.  Mac OS 9's handling of the screamer is the
         * problem -- Apple Audio Extension bombs at startup often enough to
         * be unusable, which is why soundOff above takes the node away from
         * it -- so a classic guest gets this instead, with the NDRV that
         * ppc-peaudio-loader installs.
         */
        if c.classic { a += ["-device", "poweremu-audio"] }
        /*
         * The virtual Mac's sound input.
         *
         * The emulated sound chip has always had an input channel; what it
         * did with it was stop the channel, because nothing fed it.  With
         * this on it is fed from this Mac's microphone -- but only once the
         * guest selects an input and starts recording, which is also when
         * this Mac asks whether it may listen.
         */
        if c.microphone && !c.classic { a += ["-global", "screamer.input=on"] }

        // The paravirtual GPU, alongside the emulated R200 rather than in
        // place of it: the guest keeps booting and displaying through the
        // R200, and the new device does nothing at all until a guest driver
        // opens it. Opt-in while that driver is being written, so a build
        // that ships cannot be slowed down or destabilized by a device
        // nothing in the guest is asking for yet.
        if ProcessInfo.processInfo.environment["POWEREMU_PARAVIRT_GPU"] == "1" {
            a += ["-device", "poweremu-gpu,id=pvgpu0"]
        }

        if c.networkEnabled {
            var net = "user,id=net0,ipv6=off"
            sshPort = c.sshPort.map(Self.freePort)
            if let p = sshPort { net += ",hostfwd=tcp:127.0.0.1:\(p)-:22" }
            /*
             * Sharing: the same forwarding, but listening on every address
             * of this Mac rather than only on this Mac itself, so a
             * connection from another machine on the network reaches the
             * guest. Only the services the reader asked to share.
             */
            for (service, host) in sharedPorts.sorted(by: { $0.value < $1.value }) {
                net += ",hostfwd=tcp::\(host)-:\(service.guestPort)"
            }
            // PowerEmu Tools: the guest's connections to 10.0.2.100:7700
            // reach GuestAgent's socket, one nc per connection.
            net += ",guestfwd=tcp:10.0.2.100:7700-cmd:/usr/bin/nc -U \(agentPath)"
            // Shared folders: http://10.0.2.100/ in the guest.
            net += ",guestfwd=tcp:10.0.2.100:80-cmd:/usr/bin/nc -U \(davPath)"
            // The guest's clock daemon asks the time at 10.0.2.100:7701.
            net += ",guestfwd=tcp:10.0.2.100:7701-cmd:/usr/bin/nc -U \(clockPath)"
            // The Service Hub (shared by all virtual Macs): mail at
            // 10.0.2.100 on the standard IMAP and SMTP ports.
            net += ",guestfwd=tcp:10.0.2.100:143-cmd:/usr/bin/nc -U \(ServicesHub.imapSocket)"
            net += ",guestfwd=tcp:10.0.2.100:25-cmd:/usr/bin/nc -U \(ServicesHub.smtpSocket)"
            net += ",guestfwd=tcp:10.0.2.100:587-cmd:/usr/bin/nc -U \(ServicesHub.smtpSocket)"
            net += ",guestfwd=tcp:10.0.2.100:7780-cmd:/usr/bin/nc -U \(ServicesHub.webSocket)"
            // PowerMusic: the controller in Mac OS X finds this Mac's music
            // at 10.0.2.100:3001.  Always forwarded, like the mail and the
            // web; whether anything answers is the Service Hub's switch.
            net += ",guestfwd=tcp:10.0.2.100:3001-cmd:/usr/bin/nc -U \(ServicesHub.musicSocket)"
            // The guest prints to this as an LPD printer at 10.0.2.100.
            net += ",guestfwd=tcp:10.0.2.100:515-cmd:/usr/bin/nc -U \(ServicesHub.printSocket)"
            a += ["-netdev", net, "-device", "sungem,netdev=net0"]
            /*
             * Bridged: a second card, straight on to this Mac's network
             * through the helper. The first card stays, because PowerEmu's
             * own services -- shared folders, the clipboard, the clock --
             * live on it at a fixed address the guest already knows.
             */
            if c.bridgedInterface != nil {
                unlink(bridgeEmulatorPath)
                a += ["-netdev", "dgram,id=net1,local.type=unix,local.path=\(bridgeEmulatorPath)"
                                + ",remote.type=unix,remote.path=\(bridgeHelperPath)"]
                var dev = "sungem,netdev=net1"
                if let mac = bridgeMAC { dev += ",mac=\(mac)" }
                a += ["-device", dev]
            }
        } else {
            a += ["-nic", "none"]
        }
        if c.agpBridge { a += ["-global", "uni-north-pci.agp-capable=on"] }
        if !c.bootArgs.isEmpty { a += ["-prom-env", "boot-args=\(c.bootArgs)"] }

        // Both pointing devices: the tablet takes absolute positions (seamless
        // mouse), the mouse relative movement (captured, for games).
        /*
         * Classic Mac OS gets the relative mouse only.  Mac OS 9's USB stack
         * has no driver for an absolute tablet: with one attached, QEMU routes
         * the pointer to it and the guest's cursor never moves at all, so
         * seamless mouse mode would read as a dead pointer rather than a
         * missing feature.  Measured on Mac OS 9.2.2 -- removing the tablet
         * is what made clicks arrive.
         */
        a += ["-usb", "-device", "usb-mouse,bus=usb-bus.0"]
        if !c.classic { a += ["-device", "usb-tablet,bus=usb-bus.0"] }
        a += ["-device", "usb-kbd,bus=usb-bus.0"]
        // A game controller of this Mac, as a USB gamepad in the guest
        // (GamepadServer listens on the socket; the device dials in).
        if c.gamepad {
            a += ["-device", "poweremu-gamepad,bus=usb-bus.0,path=\(gamepadPath)"]
        }

        // IDE: two buses with two units each.  The CD/DVD drive (always
        // present, so discs can be inserted while running) keeps ide.1/0; the
        // internal disks and a lent external disk fill the other three slots,
        // the startup disk first on ide.0/0.
        /*
         * Rollback.  -snapshot puts every disk behind a temporary overlay
         * that QEMU throws away when it exits, so the machine starts from the
         * same place every time and nothing it writes survives.  It applies
         * to the whole machine rather than per drive, which is exactly the
         * promise the setting makes.
         */
        if c.discardChanges { a += ["-snapshot"] }
        let cdSlot = "bus=ide.1,unit=0"
        var freeSlots = ["bus=ide.0,unit=0", "bus=ide.0,unit=1", "bus=ide.1,unit=1"]
        let hdOrder: [DiskConfig] = boot.map { b in [b] + c.hardDisks.filter { $0.id != b.id } } ?? []
        /*
         * A disc the machine remembers can be gone by the time it next
         * starts -- a Tools disc inside an app bundle that has since been
         * replaced or deleted, most commonly.  QEMU refuses to start at all
         * when it cannot open a drive's backing file, so the machine became
         * unbootable, with a raw emulator error, because of a disc that is
         * optional and merely absent.  Treat a missing one as an empty tray.
         */
        let insertedDisc: String? = {
            guard let d = c.insertedDisc else { return nil }
            if FileManager.default.fileExists(atPath: d) { return d }
            NSLog("PowerEmu: the disc %@ is gone; starting with an empty drive", d)
            return nil
        }()
        let bootCD = c.bootFromDisc && insertedDisc != nil
        // Presence matters here too: a machine told to boot from a lent disk
        // that is not there must fall back to its own startup disk, not leave
        // bootindex 0 assigned to a drive that was never added.
        let bootExternal = (c.externalDisk.map { $0.bootFrom && Self.externalDiskPresent($0) }
                            ?? false) && !bootCD
        // startup disk (a booting installer disc or external disk takes priority)
        if !hdOrder.isEmpty {
            a += hdDrive(hdOrder[0], index: 0, slot: freeSlots.removeFirst(),
                         bootIndex: (bootCD || bootExternal) ? 1 : 0)
        }
        // A blank recordable disc is opened writable and the drive is told it
        // can burn (recordable=on + POWEREMU_BURNER in the environment); every
        // other disc stays read-only.
        // The drive is created burner-capable (recordable) whenever it will
        // not be forced to open a read-only disc at boot -- i.e. an empty tray
        // or a blank recordable disc.  That lets a blank disc be dropped in and
        // burned while the machine runs, with no restart.  Booting from a
        // pressed/installer disc keeps it read-only.
        let recordable = !bootCD && (insertedDisc == nil || c.discRecordable)
        var cd = "if=none,id=cd0,media=cdrom"
        if let disc = insertedDisc {
            cd += ",file.filename=\(disc),format=\(VMConfig.imageFormat(disc))"
        }
        if !recordable { cd += ",readonly=on" }
        var cdDev = "ide-cd,\(cdSlot),drive=cd0,id=cd0dev"
        if recordable { cdDev += ",recordable=on" }
        if bootCD { cdDev += ",bootindex=0" }
        a += ["-drive", cd, "-device", cdDev]
        let extras = Array(hdOrder.dropFirst())
        let usedExtra = extras.prefix(freeSlots.count).count
        for (i, d) in extras.prefix(freeSlots.count).enumerated() {
            a += hdDrive(d, index: i + 1, slot: freeSlots[i], bootIndex: nil)
        }
        // A physical external disk, lent whole as a real IDE hard disk so it
        // can be browsed, installed onto, and booted from.  PowerEmu opens its
        // read-write file descriptor (authopen) and hands it to QEMU as
        // fd \(Self.externalChildFD) (see launch()); QEMU never opens the
        // device node itself.  The IDE bus cannot hot-plug, so it is here at
        // launch.
        if let ext = c.externalDisk, Self.externalDiskPresent(ext), usedExtra < freeSlots.count {
            // With no internal disk and no booting installer, the external is
            // the only bootable disk, so it boots even without the toggle set.
            let extBoots = bootExternal || (hdOrder.isEmpty && !bootCD)
            a += ["-add-fd", "fd=\(Self.externalReadFD),set=\(Self.externalFDSet)",
                  "-add-fd", "fd=\(Self.externalWriteFD),set=\(Self.externalFDSet)",
                  "-drive", "if=none,id=extdisk,file.filename=/dev/fdset/\(Self.externalFDSet),"
                          + "file.driver=host_device,format=raw,media=disk",
                  "-device", "ide-hd,\(freeSlots[usedExtra]),drive=extdisk"
                          + (extBoots ? ",bootindex=0" : "")]
        }

        a += ["-serial", "file:\(vm.logsURL.appendingPathComponent("console.log").path)"]
        a += ["-qmp", "unix:\(qmpPath),server=on,wait=off"]
        monitorPort = c.monitorPort.map { Self.freePort(from: $0, avoiding: sshPort) }
        if let p = monitorPort { a += ["-monitor", "telnet:127.0.0.1:\(p),server,nowait"] }
        a += ["-trace", c.gpuTrace ? "ppc_mac_gpu_*" : "ppc_mac_gpu_realize",
              "-D", vm.logsURL.appendingPathComponent("gpu-trace.log").path]
        // Waking: the machine's memory was written into its startup disk
        // when it went to sleep, and the emulator loads it instead of
        // starting Mac OS X afresh.
        if wake { a += ["-loadvm", Self.sleepTag] }
        a += c.extraQEMUArgs
        return a
    }

    private func hdDrive(_ d: DiskConfig, index i: Int, slot: String, bootIndex: Int?) -> [String] {
        let path = vm.disksURL.appendingPathComponent(d.file).path
        var drive = "if=none,id=drive\(i),file.filename=\(path),format=\(VMConfig.imageFormat(d.file))"
        drive += ",media=disk,discard=unmap,detect-zeroes=unmap"
        if d.readOnly || VMConfig.imageFormat(d.file) == "dmg" { drive += ",readonly=on" }
        var dev = "ide-hd,\(slot),drive=drive\(i)"
        if let b = bootIndex { dev += ",bootindex=\(b)" }
        return ["-drive", drive, "-device", dev]
    }

    func launch(onExit: @escaping @Sendable (Int32) -> Void) throws {
        guard let helper = Self.helperURL else { throw PackageError.missing("The emulator (PowerEmu VM.app)") }
        if let capabilities = SMPCapabilities.load(helper: helper) {
            try capabilities.verify(helper: helper)
        }
        let fw = helper.appendingPathComponent("Contents/Resources/firmware")
        try FileManager.default.createDirectory(at: vm.logsURL, withIntermediateDirectories: true)
        unlink(qmpPath)

        let qbin = helper.appendingPathComponent("Contents/MacOS/qemu-system-ppc")
        let args = try arguments(firmware: fw)
        var env = ProcessInfo.processInfo.environment
        // Burner on whenever the drive is recordable-capable (empty tray or a
        // blank disc) and not booting from a pressed disc.  Recordability of
        // any given disc is still decided by whether its backing is writable.
        if !(vm.config.bootFromDisc && vm.config.insertedDisc
                .map({ FileManager.default.fileExists(atPath: $0) }) == true) {
            env["POWEREMU_BURNER"] = "1"
            if let sock = burnStreamSocket {
                env["POWEREMU_BURN_STREAM"] = sock
            }
        }
        /*
         * The hardware cursor and a second screen were mutually exclusive for
         * a while: QEMU_PPC_NDRV installs the driver for the *machine*, not
         * for a card, so the second screen got a frame buffer advertising a
         * hardware cursor, and the guest panicked.
         *
         * That was the AGP bug wearing a different hat.  The second card was
         * being handed an AGP capability it has no GART behind, and the
         * cursor driver merely made it fire every time.  With `agp=off` on
         * the second card, measured: four desktops out of four boots with
         * this driver installed and two screens, no panic in any console
         * log -- the same configuration that panicked reliably before.
         *
         * A per-card driver, via each card's PCI expansion ROM, is still the
         * tidier answer, but nothing needs it now.
         */
        if vm.config.hardwareCursor {
            let bundled = fw.appendingPathComponent("qemu_vga_hwc.ndrv")
            if let screen = NSScreen.main,
               let original = try? Data(contentsOf: bundled),
               let patched = try? HarmonyDisplayMode.driver(original, size: HarmonyDisplayMode.size(screen: screen)) {
                let custom = vm.logsURL.appendingPathComponent("Harmony.ndrv")
                try patched.write(to: custom, options: .atomic)
                env["QEMU_PPC_NDRV"] = custom.path
            } else { env["QEMU_PPC_NDRV"] = bundled.path }
        } else {
            env.removeValue(forKey: "QEMU_PPC_NDRV")
        }
        let log = vm.logsURL.appendingPathComponent("qemu.log")
        /*
         * Keep the previous run's command line.  Truncating this on every
         * launch means the only copy of a failing configuration is destroyed
         * by the next attempt to reproduce it, which cost a whole debugging
         * session: the two-card line that panicked was gone before it could
         * be diffed against one that worked.
         */
        let prev = vm.logsURL.appendingPathComponent("qemu.log.prev")
        if FileManager.default.fileExists(atPath: log.path) {
            try? FileManager.default.removeItem(at: prev)
            try? FileManager.default.moveItem(at: log, to: prev)
        }
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let h = try FileHandle(forWritingTo: log)
        h.write(("PowerEmu: " + ([qbin.path] + args).joined(separator: " ") + "\n\n").data(using: .utf8)!)

        // An external physical disk is handed to QEMU as an open file
        // descriptor, which Foundation's Process cannot pass to a child, so
        // that machine is started with posix_spawn instead.  A disk that was
        // attached but has since been unplugged is simply left out, with a
        // note, rather than stopping the machine from starting at all.
        if let ext = vm.config.externalDisk {
            if Self.externalDiskPresent(ext) {
                try launchWithExternalDisk(ext, qbin: qbin.path, args: args, env: env, log: h, onExit: onExit)
                return
            }
            vm.note("“\(ext.displayName)” is not connected, so “\(vm.config.name)” "
                + "started without it. Reconnect the disk and attach it again from Devices.")
            if Self.externalNodePresent(ext.bsdName) {
                // The node exists but is something else now: say so, or the
                // note above reads as a lie to anyone who can see a disk there.
                vm.note("Another disk is using the name “\(ext.bsdName)” now, "
                    + "so “\(ext.displayName)” could not be identified.")
            }
        }

        let p = Process()
        p.executableURL = qbin
        p.arguments = args
        p.environment = env
        p.standardOutput = h
        p.standardError = h
        p.terminationHandler = { proc in onExit(proc.terminationStatus) }
        try p.run()
        process = p
    }

    /// Start QEMU with an external disk lent to it.  The whole host device is
    /// unmounted, opened read-write (asking for an administrator once, as the
    /// device node belongs to root), and handed down to QEMU as a fixed fd
    /// number with posix_spawn; when the machine stops the disk is given back
    /// to the host.  Opening it can put up an authorization panel, so it runs
    /// off the main thread and the machine starts (or reports failure) from
    /// the completion.
    private func launchWithExternalDisk(_ ext: ExternalDisk, qbin: String, args: [String],
                                        env: [String: String], log: FileHandle,
                                        onExit: @escaping @Sendable (Int32) -> Void) throws {
        Self.hostUnmount(ext.bsdName)
        let node = "/dev/" + ext.bsdName
        // The read-only descriptor for QEMU's mount check needs no special
        // rights (this user can read the device); only writing to it does.
        let readFD = Darwin.open(node, O_RDONLY)
        let drive = HostDrive(bsdName: ext.bsdName, name: ext.displayName, kind: .hardDisk)
        HostDrive.open(drive, writable: true) { [weak self] writeFD, err in
            Task { @MainActor in
                guard let self else { if readFD >= 0 { close(readFD) }; if writeFD >= 0 { close(writeFD) }; return }
                func fail(_ why: String) {
                    if readFD >= 0 { close(readFD) }; if writeFD >= 0 { close(writeFD) }
                    Self.hostRemount(ext.bsdName)
                    if let d = (why + "\n").data(using: .utf8) { try? log.write(contentsOf: d) }
                    onExit(1)
                }
                guard readFD >= 0 else { fail("The external disk could not be read: " + String(cString: strerror(errno)) + "."); return }
                guard writeFD >= 0 else { fail(err ?? "The external disk could not be opened for writing."); return }
                self.externalFDs = [readFD, writeFD]
                self.externalBSD = ext.bsdName
                if !self.spawn(qbin: qbin, args: args, env: env, log: log,
                               readFD: readFD, writeFD: writeFD, onExit: onExit) {
                    self.externalFDs = []
                    fail("posix_spawn failed to start the emulator.")
                }
            }
        }
    }

    /// posix_spawn QEMU, dup'ing the log onto its stdout/stderr and handing
    /// the disk's read and write descriptors down as their fixed fd numbers.
    /// Reaps the child and gives the disk back when it exits.  Returns whether
    /// it started.
    private func spawn(qbin: String, args: [String], env: [String: String], log: FileHandle,
                       readFD: Int32, writeFD: Int32, onExit: @escaping @Sendable (Int32) -> Void) -> Bool {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        let logFD = log.fileDescriptor
        posix_spawn_file_actions_adddup2(&actions, logFD, 1)
        posix_spawn_file_actions_adddup2(&actions, logFD, 2)
        posix_spawn_file_actions_adddup2(&actions, readFD, Self.externalReadFD)
        posix_spawn_file_actions_adddup2(&actions, writeFD, Self.externalWriteFD)

        let argv = ([qbin] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0)=\($1)") } + [nil]
        defer { for p in argv where p != nil { free(p) }; for p in envp where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, qbin, &actions, nil, argv, envp)
        guard rc == 0 else { return false }
        spawnPID = pid

        // Reap the child and give the disk back when it exits.
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : status & 0x7f
            src.cancel()
            Task { @MainActor in
                guard let self else { onExit(code); return }
                self.externalExitSource = nil
                self.spawnPID = 0
                for f in self.externalFDs where f >= 0 { close(f) }
                self.externalFDs = []
                if let bsd = self.externalBSD { Self.hostRemount(bsd); self.externalBSD = nil }
                onExit(code)
            }
        }
        externalExitSource = src
        src.resume()
        return true
    }

    /// Unmount every volume of a host disk (leaving the device node) so the
    /// guest can have exclusive use of it, and give it back afterwards.
    /// Whether a lent external disk's device node is actually there.  A drive
    /// that has been unplugged since it was attached must not stop the machine
    /// from starting -- it is left out instead.
    nonisolated static func externalNodePresent(_ bsd: String) -> Bool {
        return access("/dev/" + bsd, F_OK) == 0
    }

    /*
     * Is the disk we were lent still the disk sitting at that device node?
     *
     * A BSD name is not an identity.  macOS hands out disk numbers in order
     * of attachment and reuses them freely, so the disk14 a machine was given
     * last week is routinely a different device today -- a mounted disk image,
     * most often.  Testing only that /dev/disk14 exists therefore passes for
     * the wrong disk, and the machine goes on to claim it: in practice the
     * authorization fails and the machine will not start at all, reported as
     * "Access to <the drive> was not granted", which sends the reader looking
     * for a permission problem that is not there.  Worse in principle, it is
     * an invitation to hand a guest a disk nobody meant to lend it.
     *
     * So compare what is actually there now against the label the disk was
     * remembered under, built the same way HostDrives builds it.
     */
    nonisolated static func externalDiskPresent(_ ext: ExternalDisk) -> Bool {
        guard externalNodePresent(ext.bsdName) else { return false }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session,
                                                 "/dev/" + ext.bsdName),
              let desc = DADiskCopyDescription(disk) as? [String: Any]
        else { return false }
        // Only a whole external disk can have been lent in the first place.
        guard desc[kDADiskDescriptionMediaWholeKey as String] as? Bool == true,
              desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool != true
        else { return false }
        // A UUID settles it on its own where the disk has one and the machine
        // recorded it; nothing else needs to agree, and a renamed volume stops
        // mattering.
        if let want = ext.mediaUUID, let raw = desc[kDADiskDescriptionMediaUUIDKey as String] {
            let cf = raw as CFTypeRef
            guard CFGetTypeID(cf) == CFUUIDGetTypeID(),
                  let got = CFUUIDCreateString(kCFAllocatorDefault, (cf as! CFUUID))
            else { return false }
            return (got as String) == want
        }
        // Otherwise fall back to the label, as packages written before the
        // UUID was recorded must.  Size, when known, makes that much harder to
        // satisfy by accident.
        if let want = ext.sizeBytes, want > 0 {
            let got = (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0
            if got != want { return false }
        }
        let model = (desc[kDADiskDescriptionDeviceModelKey as String] as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        let volume = desc[kDADiskDescriptionVolumeNameKey as String] as? String
            ?? desc[kDADiskDescriptionMediaNameKey as String] as? String
        var label = model.isEmpty ? ext.bsdName : model
        if let volume, !volume.isEmpty { label += " (\(volume))" }
        return label == ext.label
    }
    nonisolated static func hostUnmount(_ bsd: String) {
        run("/usr/sbin/diskutil", ["unmountDisk", "force", "/dev/" + bsd])
    }
    nonisolated static func hostRemount(_ bsd: String) {
        run("/usr/sbin/diskutil", ["mountDisk", "/dev/" + bsd])
    }
    nonisolated private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// Whether an emulator for this machine is already running: its QMP
    /// socket answers.  A virtual Mac outlives a PowerEmu that crashed, and
    /// its sockets are named after the machine, so the next PowerEmu can
    /// find it again (see `adopt`).  Older PowerEmus named them otherwise,
    /// so the emulator's own command line is read as a fallback.
    func isLeftRunning() -> Bool {
        if Self.canConnect(qmpPath) { return true }
        guard let args = Self.runningEmulatorArguments(for: vm) else { return false }
        func value(_ suffix: String) -> String? {
            args.first { $0.contains("poweremu-") && $0.contains(suffix) }?
                .replacingOccurrences(of: "unix:", with: "")
                .split(separator: ",").first.map(String.init)
        }
        guard let qmp = value(".qmp"), Self.canConnect(qmp) else { return false }
        qmpPath = qmp
        agentPath = value(".agent") ?? agentPath
        davPath = value(".dav") ?? davPath
        clockPath = value(".clock") ?? clockPath
        displayPath = value(".display") ?? displayPath
        displayPath2 = value(".display2") ?? displayPath2
        return true
    }

    /// The command line of an emulator running this machine's startup disk.
    private static func runningEmulatorArguments(for vm: VirtualMachine) -> [String]? {
        guard let disk = vm.config.startupDiskConfig?.file else { return nil }
        let wanted = vm.disksURL.appendingPathComponent(disk).path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "args="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        for line in text.split(separator: "\n") where line.contains("qemu-system-ppc") && line.contains(wanted) {
            return line.split(separator: " ").map(String.init)
        }
        return nil
    }

    nonisolated static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in bytes.enumerated() { buf[i] = b } }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    /// Take charge of an emulator that is already running (PowerEmu was
    /// quit unexpectedly while it ran).  Nothing is started; the machine is
    /// watched instead, and `onExit` is called when it goes.
    func adopt(onExit: @escaping @Sendable (Int32) -> Void) {
        adoptWatch?.invalidate()
        let path = qmpPath
        adoptWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            guard !Self.canConnect(path) else { return }
            t.invalidate()
            onExit(0)
        }
    }

    /*
     * Sleep: the whole machine -- memory, processor, devices -- is written
     * into the startup disk, and the emulator then quits.  Starting again
     * with -loadvm puts it back exactly where it was, so a reader can shut
     * the app without losing what was open.
     *
     * This is QEMU's own savevm, driven through the monitor because it
     * picks the disk to write into by itself.  It takes a moment: the
     * machine's memory is gigabytes.
     */
    func sleep(_ done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "human-monitor-command",
                                  "arguments": ["command-line": "savevm \(Self.sleepTag)"]]) { r in
            if let err = QMP.errorText(r) { done(err); return }
            // The monitor reports its own failures in the returned text.
            let text = (r?["return"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            done(text.isEmpty ? nil : text)
        }
    }

    /*
     * Snapshots: the same machinery as Sleep, by name and as many as wanted.
     *
     * Sleep is one snapshot under a reserved tag that is consumed when the
     * machine wakes.  A snapshot is the same write of memory, processor and
     * devices into the disk, kept until it is thrown away, so a reader can
     * try something and come back from it.  The reserved tag is kept out of
     * the list, since it is not one of these and reverting to it would strand
     * the sleep.
     */
    func takeSnapshot(named name: String, _ done: @escaping @Sendable (String?) -> Void) {
        monitor("savevm \(Self.snapshotTag(name))", done)
    }

    func revertToSnapshot(named name: String, _ done: @escaping @Sendable (String?) -> Void) {
        monitor("loadvm \(Self.snapshotTag(name))", done)
    }

    func deleteSnapshot(named name: String, _ done: @escaping @Sendable (String?) -> Void) {
        monitor("delvm \(Self.snapshotTag(name))", done)
    }

    /// Spaces and the like would be read as further arguments by the monitor.
    static func snapshotTag(_ name: String) -> String {
        let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let t = name.unicodeScalars.map { keep.contains($0) ? Character($0) : "_" }
        let s = String(t).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return s.isEmpty ? "snapshot" : String(s.prefix(60))
    }

    private func monitor(_ command: String, _ done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "human-monitor-command",
                                  "arguments": ["command-line": command]]) { r in
            if let err = QMP.errorText(r) { done(err); return }
            let text = (r?["return"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            done(text.isEmpty ? nil : text)
        }
    }

    /*
     * What snapshots a disk holds, read with qemu-img while the machine is
     * off.  Asking the running machine would mean parsing the monitor's
     * table; the disk is the thing that actually holds them.
     */
    static func snapshots(onDisk disk: URL) -> [(tag: String, date: String, size: String)] {
        guard let helper = helperURL else { return [] }
        let img = helper.appendingPathComponent("Contents/MacOS/qemu-img")
        guard let out = try? InstallPlan.run(img.path, ["snapshot", "-l", disk.path]) else { return [] }
        var rows: [(String, String, String)] = []
        for line in String(decoding: out, as: UTF8.self).split(separator: "\n").dropFirst() {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // ID, TAG, VM SIZE, DATE, TIME, CLOCK
            guard f.count >= 5, Int(f[0]) != nil else { continue }
            let tag = f[1]
            guard tag != sleepTag else { continue }
            rows.append((tag, "\(f[3]) \(f[4])", f[2]))
        }
        return rows
    }

    /// Throw away the saved machine while the emulator is running it: a
    /// tool on this Mac cannot touch a disk the machine holds, so the
    /// emulator does it through the monitor.
    func forgetSleep() {
        QMP.shared.send(qmpPath, ["execute": "human-monitor-command",
                                  "arguments": ["command-line": "delvm \(Self.sleepTag)"]])
    }

    /// The same, for a machine that is not running.
    static func forgetSleep(disk: URL, qemuImg: URL, done: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            _ = try? InstallPlan.run(qemuImg.path, ["snapshot", "-d", sleepTag, disk.path])
            done()
        }
    }

    /// Whether a machine was left asleep in this disk.
    nonisolated static func hasSleep(disk: URL, qemuImg: URL) -> Bool {
        guard let out = try? InstallPlan.run(qemuImg.path, ["snapshot", "-l", disk.path]) else { return false }
        return String(decoding: out, as: UTF8.self).contains(sleepTag)
    }

    /// Whether the machine is running or paused right now, as the
    /// emulator sees it: a machine taken back after PowerEmu restarted may
    /// have been left paused.
    func askIfPaused(_ done: @escaping @Sendable (Bool) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "query-status"]) { reply in
            let ret = reply?["return"] as? [String: Any]
            done((ret?["status"] as? String) == "paused")
        }
    }

    /// Stop the guest's processor where it stands, and let it go again.
    /// Nothing inside the virtual Mac runs while it is paused: the screen
    /// holds its last frame and no time passes for the guest.
    func pause(_ done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "stop"]) { r in done(QMP.errorText(r)) }
    }

    func resume(_ done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "cont"]) { r in done(QMP.errorText(r)) }
    }

    /// Whether the machine is still there: the process we started, or -- for
    /// one we adopted -- something still answering on its socket.
    func isAlive() -> Bool {
        if spawnPID != 0 { return kill(spawnPID, 0) == 0 }
        if let p = process { return p.isRunning }
        return Self.canConnect(qmpPath)
    }

    func pressPowerKey() {
        QMP.shared.send(qmpPath, ["execute": "send-key",
                                  "arguments": ["keys": [["type": "qcode", "data": "power"]]]])
    }

    /// Give a USB device of this Mac to the guest (QEMU usb-host), or take
    /// it back.  `done` gets an error to show, or nil.
    func attachUSB(_ d: HostUSBDevice, done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "device_add",
                                  "arguments": ["driver": "usb-host", "id": d.id, "bus": "usb-bus.0",
                                                "vendorid": d.vendor, "productid": d.product]]) { r in
            done(QMP.errorText(r))
        }
    }

    func detachUSB(_ id: String, done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "device_del", "arguments": ["id": id]]) { r in
            done(QMP.errorText(r))
        }
    }

    func terminate() {
        adoptWatch?.invalidate()
        adoptWatch = nil
        QMP.shared.send(qmpPath, ["execute": "quit"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            if let p = self.process, p.isRunning { p.terminate() }
            if self.spawnPID != 0, kill(self.spawnPID, 0) == 0 { kill(self.spawnPID, SIGTERM) }
        }
    }

    /// Put a disc image in the CD/DVD drive.  A disc already in it is
    /// ejected first, asking Mac OS X as the Eject button does.
    /// Put a blank recordable disc in the drive, opened writable so the guest
    /// can burn to it.  Needs the drive to have been created burner-capable
    /// (recordable=on), which it is whenever it booted with an empty tray.
    func insertRecordableDisc(_ path: String, done: @escaping @Sendable (String?) -> Void) {
        let qmp = qmpPath
        ejectDisc { err in
            if let err { done(err); return }
            QMP.shared.send(qmp, ["execute": "blockdev-change-medium",
                                  "arguments": ["id": "cd0dev", "filename": path,
                                                "format": "raw",
                                                "read-only-mode": "read-write"]]) { reply in
                done(QMP.errorText(reply))
            }
        }
    }

    func insertDisc(_ path: String, done: @escaping @Sendable (String?) -> Void) {
        let qmp = qmpPath
        ejectDisc { err in
            if let err { done(err); return }
            QMP.shared.send(qmp, ["execute": "blockdev-change-medium",
                                  "arguments": ["id": "cd0dev", "filename": path,
                                                "format": VMConfig.imageFormat(path),
                                                "read-only-mode": "read-only"]]) { reply in
                done(QMP.errorText(reply))
            }
        }
    }

    /// Put a host device (already opened, e.g. by authopen) in the drive.
    /// QEMU gets the open file over the socket (an fdset) and reads it with
    /// its host_device driver, the one for raw disks.
    func insertDevice(fd: Int32, done: @escaping @Sendable (String?) -> Void) {
        let path = qmpPath
        ejectDisc { err in
            if let err { done(err); return }
            QMP.shared.send(path, ["execute": "add-fd"], passing: fd) { reply in
                guard let r = reply?["return"] as? [String: Any], let set = r["fdset-id"] as? Int else {
                    done(QMP.errorText(reply) ?? "The emulator did not accept the drive.")
                    return
                }
                QMP.shared.sequence(path, [
                    ["execute": "blockdev-add",
                     "arguments": ["driver": "raw", "node-name": Self.hostNode, "read-only": true,
                                   "file": ["driver": "host_device", "filename": "/dev/fdset/\(set)",
                                            "read-only": true]]],
                    ["execute": "blockdev-insert-medium", "arguments": ["id": "cd0dev", "node-name": Self.hostNode]],
                    ["execute": "blockdev-close-tray", "arguments": ["id": "cd0dev"]],
                ]) { err in
                    if err != nil { Self.releaseHostDevice(path) }
                    done(err)
                }
            }
        }
    }

    /// The block node for a host drive; one drive, so one name.
    nonisolated static let hostNode = "hostdrive"

    /// Close a host drive that has left the virtual drive.  Harmless when
    /// there is none.
    nonisolated static func releaseHostDevice(_ path: String, done: (@Sendable () -> Void)? = nil) {
        QMP.shared.send(path, ["execute": "blockdev-del", "arguments": ["node-name": hostNode]]) { _ in
            QMP.shared.send(path, ["execute": "query-fdsets"]) { reply in
                let sets = (reply?["return"] as? [[String: Any]] ?? []).compactMap { $0["fdset-id"] as? Int }
                for id in sets {
                    QMP.shared.send(path, ["execute": "remove-fd", "arguments": ["fdset-id": id]])
                }
                QMP.shared.send(path, ["execute": "query-status"]) { _ in done?() }
            }
        }
    }

    /// Eject the way a Mac does: while Mac OS X has the disc mounted it keeps
    /// the tray locked.  Mac OS X never looks at the drive's own eject
    /// request, so PowerEmu holds down F12 - the eject key on keyboards
    /// without one - and Mac OS X unmounts the disc and opens the tray; then
    /// the disc can be taken out.  Only `force` pulls it regardless (the
    /// guest may be left with a stale mount).
    func ejectDisc(force: Bool = false, done: @escaping @Sendable (String?) -> Void) {
        let path = qmpPath
        let pull: @Sendable () -> Void = {
            QMP.shared.send(path, ["execute": "eject", "arguments": ["id": "cd0dev", "force": force]]) { r in
                if let e = QMP.errorText(r) { done(e) } else { Self.releaseHostDevice(path) { done(nil) } }
            }
        }
        if force { pull(); return }
        Self.driveState(path) { inserted, locked in
            // Empty: just open the tray (inserting needs it open).
            guard inserted else { pull(); return }
            // Mac OS X locks the tray while the disc is mounted, but not
            // always, so ask it every time; an unlocked drive whose disc Mac
            // OS X doesn't answer for is simply opened.
            QMP.shared.send(path, ["execute": "send-key",
                                   "arguments": ["keys": [["type": "qcode", "data": "f12"]], "hold-time": 1500]]) { _ in }
            Self.waitForTray(path, tries: locked ? 20 : 4) { opened in
                if opened {
                    QMP.shared.send(path, ["execute": "blockdev-remove-medium", "arguments": ["id": "cd0dev"]]) { r in
                        if let e = QMP.errorText(r) { done(e) } else { Self.releaseHostDevice(path) { done(nil) } }
                    }
                } else if !locked {
                    pull()
                } else {
                    done(Self.discInUse)
                }
            }
        }
    }

    nonisolated static let discInUse = "Mac OS X is still using the disc. Quit programs using it, or drag it to the Trash in the virtual Mac, then eject again."

    /// Whether the drive holds a disc, and whether the guest has locked it.
    private nonisolated static func driveState(_ path: String, done: @escaping @Sendable (Bool, Bool) -> Void) {
        QMP.shared.send(path, ["execute": "query-block"]) { reply in
            let devs = reply?["return"] as? [[String: Any]] ?? []
            let cd = devs.first { ($0["qdev"] as? String)?.contains("cd0dev") == true || ($0["device"] as? String) == "cd0" }
            done(cd?["inserted"] != nil, cd?["locked"] as? Bool ?? false)
        }
    }

    private nonisolated static func waitForTray(_ path: String, tries: Int, done: @escaping @Sendable (Bool) -> Void) {
        QMP.shared.send(path, ["execute": "query-block"]) { reply in
            let devs = reply?["return"] as? [[String: Any]] ?? []
            let cd = devs.first { ($0["qdev"] as? String)?.contains("cd0dev") == true || ($0["device"] as? String) == "cd0" }
            if cd?["tray_open"] as? Bool == true || cd?["inserted"] == nil { done(true); return }
            if tries <= 0 { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { waitForTray(path, tries: tries - 1, done: done) }
        }
    }

    /// The emulator process, for the overlay's host-side sampling. nil when
    /// no VM is running, which the overlay shows as no host figures rather
    /// than as zeroes -- a zero reads as "idle", which is a different claim.
    var qemuPID: pid_t? {
        if spawnPID != 0 { return kill(spawnPID, 0) == 0 ? spawnPID : nil }
        guard let p = process, p.isRunning else { return nil }
        return p.processIdentifier
    }

    /*
     * The GPU model's running totals ("frames=… draws=… …"), for the
     * performance overlay.
     *
     * `screen` picks the card: a second guest screen is a second card with
     * its own frame counter, so each window's overlay asks its own card and
     * reports its own rate.  The totals used to be one set shared by both
     * cards, which made the overlay add two screens' frames together and
     * show the sum on each.
     */
    func queryPerf(screen: Int = 0, done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "qom-get",
                                  "arguments": ["path": "/machine/peripheral/gpu\(screen)",
                                                "property": "perf"]]) { reply in
            done(reply?["return"] as? String)
        }
    }

    /// What is in the drive now (the guest can eject it): the image path,
    /// "" for a host device, nil when empty.
    func queryDisc(done: @escaping @Sendable (String?) -> Void) {
        let path = qmpPath
        QMP.shared.send(path, ["execute": "query-block"]) { reply in
            let devs = reply?["return"] as? [[String: Any]] ?? []
            let cd = devs.first { ($0["qdev"] as? String)?.contains("cd0dev") == true || ($0["device"] as? String) == "cd0" }
            let ins = cd?["inserted"] as? [String: Any]
            // Mac OS X ejected it (the disc was dragged to the Trash): the
            // tray stands open with the disc in it, so take it out.
            if ins != nil, cd?["tray_open"] as? Bool == true {
                QMP.shared.send(path, ["execute": "blockdev-remove-medium", "arguments": ["id": "cd0dev"]]) { _ in
                    Self.releaseHostDevice(path) { done(nil) }
                }
                return
            }
            let file = ins?["file"] as? String
            done(file.map { $0.hasPrefix("/dev/fdset") ? "" : $0 })
        }
    }
}

/// QMP client: one short connection per command, serialized.  Commands can
/// carry a file descriptor (SCM_RIGHTS), which is how add-fd receives host
/// devices the emulator could not open itself.
final class QMP: @unchecked Sendable {
    static let shared = QMP()
    private let queue = DispatchQueue(label: "poweremu.qmp")

    /// Send commands one after another, stopping at the first error.
    func sequence(_ socketPath: String, _ commands: [[String: Any]],
                  done: @escaping @Sendable (String?) -> Void) {
        guard let first = commands.first else { done(nil); return }
        send(socketPath, first) { reply in
            if let err = Self.errorText(reply) { done(err); return }
            self.sequence(socketPath, Array(commands.dropFirst()), done: done)
        }
    }

    static func errorText(_ reply: [String: Any]?) -> String? {
        guard let reply else { return "The emulator did not answer." }
        if let e = reply["error"] as? [String: Any] { return e["desc"] as? String ?? "Error" }
        return nil
    }

    func send(_ socketPath: String, _ command: [String: Any], passing fd: Int32 = -1,
              reply: (@Sendable ([String: Any]?) -> Void)? = nil) {
        queue.async {
            let r = Self.exchange(socketPath, command, fd: fd)
            if let reply { DispatchQueue.main.async { reply(r) } }
        }
    }

    private static func exchange(_ path: String, _ command: [String: Any], fd passFD: Int32) -> [String: Any]? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in bytes.enumerated() { buf[i] = b } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        // Commands wait for the emulator's big lock, which a busy guest can
        // hold for a while.
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var pending = Data()
        func readMessage() -> [String: Any]? {
            // QMP messages are JSON objects, one per line; skip events.
            while true {
                if let nl = pending.firstIndex(of: 0x0a) {
                    let line = pending[pending.startIndex..<nl]
                    pending.removeSubrange(pending.startIndex...nl)
                    if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        if obj["event"] != nil { continue }
                        return obj
                    }
                    continue
                }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = read(fd, &buf, buf.count)
                if n <= 0 { return nil }
                pending.append(contentsOf: buf[0..<n])
            }
        }
        func write(_ obj: [String: Any], fd extra: Int32 = -1) -> Bool {
            guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return false }
            d.append(0x0a)
            if extra < 0 {
                return d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, d.count) } == d.count
            }
            return sendWithFD(socket: fd, data: d, passing: extra)
        }
        _ = readMessage()                                   // greeting
        guard write(["execute": "qmp_capabilities"]) else { return nil }
        _ = readMessage()
        guard write(command, fd: passFD) else { return nil }
        return readMessage()
    }

    /// sendmsg with one SCM_RIGHTS descriptor.  Darwin aligns control data to
    /// 4 bytes: CMSG_SPACE(4) = CMSG_LEN(4) = 16.
    static func sendWithFD(socket: Int32, data: Data, passing passFD: Int32) -> Bool {
        var control = [UInt8](repeating: 0, count: 16)
        control.withUnsafeMutableBytes { c in
            c.storeBytes(of: UInt32(16), toByteOffset: 0, as: UInt32.self)          // cmsg_len
            c.storeBytes(of: Int32(SOL_SOCKET), toByteOffset: 4, as: Int32.self)    // cmsg_level
            c.storeBytes(of: Int32(SCM_RIGHTS), toByteOffset: 8, as: Int32.self)    // cmsg_type
            c.storeBytes(of: passFD, toByteOffset: 12, as: Int32.self)
        }
        var d = data
        return d.withUnsafeMutableBytes { dp -> Bool in
            control.withUnsafeMutableBytes { cp -> Bool in
                var iov = iovec(iov_base: dp.baseAddress, iov_len: dp.count)
                return withUnsafeMutablePointer(to: &iov) { iovp -> Bool in
                    var msg = msghdr()
                    msg.msg_iov = iovp
                    msg.msg_iovlen = 1
                    msg.msg_control = cp.baseAddress
                    msg.msg_controllen = socklen_t(cp.count)
                    return sendmsg(socket, &msg, 0) == dp.count
                }
            }
        }
    }

    /// recvmsg one SCM_RIGHTS descriptor (from authopen -stdoutpipe).
    static func receiveFD(socket: Int32) -> Int32 {
        var byte = [UInt8](repeating: 0, count: 256)
        var control = [UInt8](repeating: 0, count: 16)
        return byte.withUnsafeMutableBytes { bp -> Int32 in
            control.withUnsafeMutableBytes { cp -> Int32 in
                var iov = iovec(iov_base: bp.baseAddress, iov_len: bp.count)
                return withUnsafeMutablePointer(to: &iov) { iovp -> Int32 in
                    var msg = msghdr()
                    msg.msg_iov = iovp
                    msg.msg_iovlen = 1
                    msg.msg_control = cp.baseAddress
                    msg.msg_controllen = socklen_t(cp.count)
                    guard recvmsg(socket, &msg, 0) >= 0, msg.msg_controllen >= 16 else { return -1 }
                    let type = cp.load(fromByteOffset: 8, as: Int32.self)
                    return type == SCM_RIGHTS ? cp.load(fromByteOffset: 12, as: Int32.self) : -1
                }
            }
        }
    }
}
