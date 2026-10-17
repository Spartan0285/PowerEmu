import AppKit

// Own-window WindowServer integration check; does not drive other applications.
@main
@MainActor
final class OcclusionChecks: NSObject, NSApplicationDelegate {
    var background: NSWindow!
    var cover: NSWindow!
    var scheduler = HarmonyCaptureScheduler()
    var timer: Timer?
    var stage = 0
    var attempts = 0

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let checks = OcclusionChecks()
        app.delegate = checks
        withExtendedLifetime(checks) { app.run() }
    }
    func finish(_ message: String, code: Int32) -> Never {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
        exit(code)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduler.suspendOccluded = true
        background = NSWindow(contentRect: NSRect(x: 250, y: 250, width: 200, height: 150),
                              styleMask: [.titled], backing: .buffered, defer: false)
        background.title = "Harmony occlusion background fixture"
        background.backgroundColor = .red
        cover = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 360, height: 310),
                         styleMask: [.titled], backing: .buffered, defer: false)
        cover.title = "Harmony occlusion cover fixture"
        cover.backgroundColor = .blue
        background.orderFront(nil)
        cover.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }
    func step() {
        let now = ProcessInfo.processInfo.systemUptime
        if stage == 0 {
            attempts += 1
            if (!cover.occlusionState.contains(.visible) || background.occlusionState.contains(.visible)) && attempts < 6 { return }
            guard cover.occlusionState.contains(.visible),
                  !background.occlusionState.contains(.visible) else {
                finish("UNSCORED: own-window occlusion background=\(background.occlusionState.rawValue) cover=\(cover.occlusionState.rawValue) active=\(NSApp.isActive)", code: 2)
            }
            scheduler.completed(1, unchanged: false, visible: false, now: now - 10)
            for tick in 0..<20 {
                let time = now + Double(tick) * 0.1
                guard scheduler.next([.init(id: 1, needsImage: false, visible: false),
                                      .init(id: 2, needsImage: false, visible: true)],
                                     foreground: 2, now: time) == 2 else {
                    finish("FAIL: covered window consumed a foreground capture slot", code: 1)
                }
                scheduler.completed(2, unchanged: false, visible: true, now: time)
            }
            cover.orderOut(nil)
            stage = 1
        } else {
            guard background.occlusionState.contains(.visible) else {
                finish("UNSCORED: background was not exposed after removing the cover", code: 2)
            }
            guard scheduler.next([.init(id: 1, needsImage: false, visible: true)],
                                 foreground: nil, now: now + 3) == 1 else {
                finish("FAIL: exposed window did not become eligible immediately", code: 1)
            }
            background.orderOut(nil)
            finish("PASS: actual AppKit covered/exposed states suspend and resume capture eligibility", code: 0)
        }
    }
}
