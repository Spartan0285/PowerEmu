import Foundation
import AppKit

/*
 * Printing from the virtual Mac, by being a printer it already knows how to
 * talk to.
 *
 * Every Mac OS worth emulating can print to a line printer daemon over TCP:
 * Mac OS X adds one as an LPD printer, and Mac OS 8/9 through the Desktop
 * Printer Utility's "Printer (LPR)".  So rather than teaching the guest
 * anything, PowerEmu answers RFC 1179 on the address the guest already reaches
 * its other services on, takes the job, and hands it to this Mac.
 *
 * What arrives is PostScript from a classic guest and PostScript or PDF from
 * Mac OS X.  A PDF this Mac can open or print directly.  PostScript it cannot
 * open any more -- Preview dropped it, and there is no pstopdf -- but CUPS
 * still carries pstops and pstoappleps, so `lp` can still print it.  That is
 * the difference between the two destinations below, and it is why sending to
 * a real printer is the one that always works.
 */
final class PrinterServer: @unchecked Sendable {
    struct Settings {
        /// A CUPS printer name, or "" to keep the file and open it.
        var destination = ""
    }

    private let lock = NSLock()
    private var settings = Settings()
    private let note: @Sendable (String) -> Void

    init(note: @escaping @Sendable (String) -> Void) { self.note = note }

    func update(_ s: Settings) { lock.lock(); settings = s; lock.unlock() }

    /// Where jobs are kept.  They are small and a reader may want the last one
    /// back, so they are not deleted behind their back.
    static var spool: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerEmu/Print Jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: the protocol

    func serve(fd: Int32, peer: String) {
        defer { close(fd) }
        guard let first = readLine(fd), let cmd = first.first else { return }
        // 0x02 is "receive a printer job"; anything else is a queue query we
        // have no answer for, and saying so is better than hanging.
        guard cmd == 0x02 else { _ = write(fd, [UInt8(1)], 1); return }
        ack(fd)

        var data = Data()
        var jobName = "Untitled"
        while let line = readLine(fd), let sub = line.first {
            switch sub {
            case 0x01:                      // abort
                return
            case 0x02, 0x03:                // control file, then data file
                let rest = String(decoding: line.dropFirst(), as: UTF8.self)
                let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
                let count = Int(parts.first ?? "") ?? 0
                ack(fd)
                guard let payload = readExactly(fd, count) else { return }
                _ = readExactly(fd, 1)      // the trailing zero
                ack(fd)
                if sub == 0x03 {
                    data = payload
                } else if let n = Self.jobName(fromControlFile: payload) {
                    jobName = n
                }
            default:
                return
            }
        }
        guard !data.isEmpty else { return }
        deliver(data, jobName: jobName)
    }

    private func ack(_ fd: Int32) { _ = write(fd, [UInt8(0)], 1) }

    /// The control file carries the job's name on an "N" line.
    private static func jobName(fromControlFile d: Data) -> String? {
        for line in String(decoding: d, as: UTF8.self).split(separator: "\n") where line.hasPrefix("N") {
            let n = line.dropFirst().trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { return n }
        }
        return nil
    }

    // MARK: delivery

    private func deliver(_ data: Data, jobName: String) {
        let pdf = data.starts(with: Array("%PDF".utf8))
        let ps = data.starts(with: Array("%!".utf8))
        let ext = pdf ? "pdf" : (ps ? "ps" : "prn")
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let safe = jobName.replacingOccurrences(of: "/", with: "-")
        let file = Self.spool.appendingPathComponent("\(stamp) \(safe).\(ext)")
        do { try data.write(to: file) } catch {
            note("Could not save the print job: \(error.localizedDescription)")
            return
        }

        lock.lock(); let dest = settings.destination; lock.unlock()
        if !dest.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/lp")
            p.arguments = ["-d", dest, "-t", jobName, file.path]
            do {
                try p.run(); p.waitUntilExit()
                note(p.terminationStatus == 0
                     ? "Printed “\(jobName)” on \(dest)."
                     : "\(dest) refused “\(jobName)” (lp exited \(p.terminationStatus)); kept at \(file.path)")
            } catch {
                note("Could not reach lp: \(error.localizedDescription); kept at \(file.path)")
            }
            return
        }
        if pdf {
            NSWorkspace.shared.open(file)
            note("Opened “\(jobName)”.")
        } else {
            /*
             * Say what it is rather than opening something that will not
             * open.  PostScript needs a printer, or Ghostscript, neither of
             * which this can assume.
             */
            note("Saved “\(jobName)” as PostScript at \(file.path). "
                 + "Choose a printer to print these directly.")
        }
    }

    // MARK: reading a socket that has no framing of its own

    private func readLine(_ fd: Int32) -> [UInt8]? {
        var out: [UInt8] = []
        var c: UInt8 = 0
        while true {
            let n = read(fd, &c, 1)
            if n <= 0 { return out.isEmpty ? nil : out }
            if c == 0x0a { return out }
            out.append(c)
            if out.count > 4096 { return out }      // a line this long is not one
        }
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        guard count >= 0 else { return nil }
        var out = Data(); out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while out.count < count {
            let want = min(buf.count, count - out.count)
            let n = read(fd, &buf, want)
            if n <= 0 { return nil }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }
}
