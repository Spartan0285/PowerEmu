import AppKit
import SwiftUI

/*
 * The About window.
 *
 * Its contents and their order are from "Garden OSX/docs/ADDING-AN-APP.md":
 * what the app is, what it is not, that it is an alpha, and who made it.
 * The standard About panel cannot carry any of that, so each app draws its
 * own.
 *
 * One thing from that document deliberately does not apply here. Section 8
 * has every app in the family route its links through Captain Polliwog,
 * because Safari on Tiger and Leopard stops at TLS 1.0 and cannot open
 * cytrusretro.com at all. PowerEmu is the one app in the family that runs on
 * the *host* -- a current macOS, whose browser has no such problem -- so the
 * links here go straight to the default browser.
 */

@MainActor
final class AboutWindowController: NSWindowController {
    private static var shared: AboutWindowController?

    static func present() {
        if let existing = shared, let w = existing.window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "About PowerEmu"
        window.styleMask = [.titled, .closable]
        window.center()
        let c = AboutWindowController(window: window)
        shared = c
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Icon, name, version and build, stage badge. The build
            //    number is what a feedback report carries, so it is what we
            //    will ask someone for.
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("PowerEmu").font(.system(size: 20, weight: .semibold))
                        if !Feedback.stage.isEmpty {
                            Text(Feedback.stage.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.9)))
                                .foregroundStyle(.black)
                        }
                    }
                    Text("Version \(Feedback.version) (build \(Feedback.build))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Mac OS X 10.4 and 10.5 for PowerPC, on Apple silicon.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 14)

            Divider().padding(.bottom, 12)

            // 2. The alpha sentence. An invitation, not a disclaimer: it is
            //    what turns an annoyed person into a reporter.
            Text("This is an alpha build. Expect rough edges, and please say when you find one.")
                .font(.system(size: 11, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            // 3. What it is not. Said plainly and early, not buried.
            Text("PowerEmu is not affiliated with Apple. It emulates a Power Macintosh; "
               + "it does not include Mac OS X. You supply your own installation media.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            // 4. Who made it. First person, all the way through.
            Text("Cytrus Software (a.k.a. Cytrus Retro) is a personal side project by me, "
               + "Adam Cipoletti, a Creative Director and Career Coach. You can find more "
               + "of my vintage software and hardware projects at cytrusretro.com.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            // 5. The Cytrus Software lockup: the mark, then the name beside
            //    it. The logo's own wordmark is set in a face no Mac here
            //    has, so only the mark is shipped and the name is drawn.
            HStack(spacing: 8) {
                if let mark = NSImage(named: "cytrusmark") {
                    Image(nsImage: mark)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 40)
                }
                VStack(alignment: .leading, spacing: -2) {
                    Text("CYTRUS").font(.system(size: 17, weight: .bold))
                    Text("SOFTWARE").font(.system(size: 10, weight: .semibold))
                        .tracking(1.5)
                }
                Spacer()
            }
            .padding(.bottom, 14)

            // 6. The two buttons. The ink is picked from the fill, not by
            //    habit: white on lime is unreadable.
            HStack(spacing: 10) {
                BrandButton(title: "cytrusretro.com",
                            fill: Color(red: 0xA8/255, green: 0xD8/255, blue: 0x1A/255),
                            ink: Color(red: 0x1A/255, green: 0x2A/255, blue: 0x00/255),
                            url: "https://www.cytrusretro.com/")
                BrandButton(title: "amcreativecoach.com",
                            fill: Color(red: 0x6F/255, green: 0x2E/255, blue: 0x7E/255),
                            ink: .white,
                            url: "https://www.amcreativecoach.com/")
                Spacer()
            }
        }
        .padding(20)
        // An explicit width, and no Spacer above: a Spacer makes SwiftUI's
        // fitting height unbounded, and NSHostingController then sizes the
        // window to it -- this one came out 5879 points tall, with the
        // buttons somewhere below the desk.
        .frame(width: 420, alignment: .leading)
    }
}

private struct BrandButton: View {
    let title: String
    let fill: Color
    let ink: Color
    let url: String

    var body: some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        }
        .buttonStyle(.plain)
    }
}
