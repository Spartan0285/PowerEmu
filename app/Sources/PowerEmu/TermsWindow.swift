//  TermsWindow.swift
//  What somebody should know before the first time they use PowerEmu.
//
//  The words live in TERMS.md at the top of the repository, copied into the
//  bundle by build-app.sh, so the version people read in the app and the
//  version anybody can read on the web are the same file.

import SwiftUI
import AppKit

enum Terms {
    /// Raise this when the terms change in a way worth reading again;
    /// everyone is asked once more.  Leave it alone for a typo.
    static let version = 1

    private static let acceptedKey = "PETermsAcceptedVersion"

    static var accepted: Bool {
        UserDefaults.standard.integer(forKey: acceptedKey) >= version
    }

    static func accept() {
        UserDefaults.standard.set(version, forKey: acceptedKey)
    }

    static var text: String {
        guard let url = Bundle.main.url(forResource: "TERMS", withExtension: "md"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            // Shipping without them is a mistake, but refusing to open is a
            // worse one: say so and let the reader carry on.
            return "# Before you use PowerEmu\n\nThe terms could not be found in "
                 + "this copy of PowerEmu. They are at "
                 + "https://github.com/Spartan0285/PowerEmu/blob/main/TERMS.md\n"
        }
        return s
    }
}

/// Markdown, but only the parts these terms use: headings, paragraphs,
/// points, and **bold** within a line.  Anything cleverer would be one more
/// thing to go wrong in front of somebody who has not used PowerEmu yet.
struct TermsTextView: View {
    let markdown: String

    private struct Block: Identifiable {
        let id = UUID()
        enum Kind { case title, heading, paragraph, bullet }
        let kind: Kind
        let text: String
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph = ""
        func flush() {
            let t = paragraph.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(Block(kind: .paragraph, text: t)) }
            paragraph = ""
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("## ") {
                flush(); out.append(Block(kind: .heading, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flush(); out.append(Block(kind: .title, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                flush(); out.append(Block(kind: .bullet, text: String(line.dropFirst(2))))
            } else {
                paragraph += paragraph.isEmpty ? line : " " + line
            }
        }
        flush()
        return out
    }

    /// The **bold** and the <links>; anything it cannot read comes through
    /// as the characters that were written, which is no worse than plain.
    private func styled(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { b in
                switch b.kind {
                case .title:
                    Text(styled(b.text)).font(.title2).bold()
                case .heading:
                    Text(styled(b.text)).font(.headline).padding(.top, 8)
                case .paragraph:
                    Text(styled(b.text)).fixedSize(horizontal: false, vertical: true)
                case .bullet:
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{2022}")
                        Text(styled(b.text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TermsView: View {
    /// Nil when the reader is only re-reading them from Settings: there is
    /// nothing left to accept, so there is nothing to ask.
    var onAccept: (() -> Void)?
    var onQuit: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                TermsTextView(markdown: Terms.text).padding(24)
            }
            if onAccept != nil {
                Divider()
                HStack {
                    Button("Quit") { onQuit?() }
                    Spacer()
                    Button("I Understand") { onAccept?() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 560)
    }
}

@MainActor
final class TermsWindowController: NSWindowController, NSWindowDelegate {
    private static var reading: TermsWindowController?

    /// Shown before anything else the first time, and again if the terms
    /// change.  The app waits here: agreeing to use something afterwards is
    /// not agreeing to it.
    static func presentIfNeeded() {
        guard !Terms.accepted else { return }
        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "PowerEmu"
        window.isReleasedWhenClosed = false
        let view = TermsView(
            onAccept: {
                Terms.accept()
                NSApp.stopModal()
                window.orderOut(nil)
            },
            onQuit: {
                NSApp.stopModal()
                window.orderOut(nil)
                NSApp.terminate(nil)
            })
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        NSApp.activate(ignoringOtherApps: true)

        /*
         * A modal session takes the Quit menu item with it, so Command-Q
         * does nothing -- and somebody who does not want to go on would be
         * left with a window they cannot leave except through the button we
         * chose to draw.  That is not a position to put anybody in, so
         * Command-Q is put back by hand for as long as the terms are up.
         */
        let quitKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  e.charactersIgnoringModifiers?.lowercased() == "q" else { return e }
            NSApp.stopModal()
            window.orderOut(nil)
            NSApp.terminate(nil)
            return nil
        }
        defer { NSEvent.removeMonitor(quitKey) }

        NSApp.runModal(for: window)
    }

    /// Settings -> read them again.  No buttons: nothing to decide.
    static func present() {
        if let r = reading {
            r.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: TermsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "PowerEmu Terms and Conditions"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        let c = TermsWindowController(window: window)
        window.delegate = c
        reading = c
        c.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        TermsWindowController.reading = nil
    }
}
