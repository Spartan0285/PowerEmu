import Foundation

/*
 * Finishing a fresh Mac OS X install.
 *
 * A machine installed from a retail 10.4 disc boots, runs, and never shows a
 * desktop. Its WindowServer rejects the emulated framebuffer and quietly
 * substitutes a VirtualDisplay, so everything works except the picture:
 *
 *     Display 0x41dc9d00: VirtualDisplay Unit 0; Vendor 0x756e6b6e
 *       Model 0x76697274 ... (0,0)[1024 x 768]
 *
 * ("unkn" and "virt" in ASCII.) On 10.4.11 the same emulated card gets a
 * MappedDisplay and a working desktop, so the defect is in 10.4.0's graphics
 * stack and not in ppc-mac-gpu -- confirmed by the guest never touching the
 * card's MMIO during a whole boot, only its PCI config space.
 *
 * The cure is Apple's 10.4.11 combo update. PowerEmu cannot ship it: it is
 * Apple's software, and a free download is not a redistributable one. So the
 * reader fetches it from Apple and PowerEmu installs it for them, from a
 * disc, with no guest networking involved -- Software Update needs a fully
 * booted system with a network, which is exactly what a machine in this
 * state cannot provide.
 *
 * Verified by hand on 2026-09-21: installer reports success, and the machine
 * that had never shown anything but console text came up drawing the desktop.
 */
enum PostInstall {
    /// Where Apple publishes the update the guest needs.
    static let appleDownloadPage =
        URL(string: "https://support.apple.com/en-us/106535")!

    /// What the reader is asked to find, so the file panel and the prose
    /// agree with what Apple's page actually offers.
    static let updaterFileName = "MacOSXUpdCombo10.4.11PPC.dmg"

    /// The steps, in order, once a single-user prompt is waiting.
    ///
    /// Each is deliberately short. An earlier version typed these through
    /// the monitor with `sendkey` and lost characters out of the longer
    /// ones -- `-target /` arrived as `get/`, the install never started, and
    /// it looked for all the world like a hang. Whatever drives these must
    /// read back what it sent.
    static func steps(discSlice: String = "/dev/disk1s0s3") -> [Step] {
        [
            Step(command: "/sbin/mount -uw /",
                 note: "Preparing the disk"),
            // installer needs DiskArbitration and friends, which single user
            // does not start; /etc/rc brings them up and leaves the shell.
            Step(command: "sh /etc/rc > /dev/null 2>&1",
                 note: "Starting services", expectSlow: true),
            Step(command: "mkdir -p /upd; mount -t hfs -o rdonly \(discSlice) /upd",
                 note: "Reading the update"),
            Step(command: "cd /upd && installer -pkg *.pkg -target /",
                 note: "Installing Mac OS X 10.4.11", expectSlow: true),
            Step(command: "cd /; umount /upd; sync; sync; halt",
                 note: "Finishing up", expectSlow: true),
        ]
    }

    struct Step {
        let command: String
        /// Shown to the reader while it runs. Plain words, not the command.
        let note: String
        /// Minutes rather than seconds; the progress UI should not give up.
        var expectSlow = false
    }

    /// `installer` prints these; they are the only progress it offers.
    static func progressNote(from line: String) -> String? {
        if line.contains("Package name is") { return "Reading the update" }
        if line.contains("Installing onto volume") { return "Installing Mac OS X 10.4.11" }
        if line.contains("The install was successful") { return "Update installed" }
        return nil
    }

    static func succeeded(_ transcript: String) -> Bool {
        transcript.contains("The install was successful")
    }

    /*
     * Two things this has to survive, both seen on the verified run:
     *
     * 1. The shutdown after a successful install panicked the old kernel
     *    ("0x300 - Data access") while halting. The journal covered it and
     *    the next boot was fine, but the driver must treat a panic at this
     *    point as expected rather than as failure -- the install is already
     *    on disk by then, and `succeeded` above is what decides.
     *
     * 2. installer asks for a restart, and that restart is where the new
     *    kernel and caches take effect. The machine must come back up with
     *    the updater disc detached, or it will simply sit there.
     */
}
