//  WhatsNewWindow.swift
//  What changed: once after an update, and whenever it is asked for.

import SwiftUI
import AppKit

/// Release notes as written: blank lines separate paragraphs, a line
/// starting with "- " or "* " is a point, a line starting with "#" is a
/// heading.  Deliberately not full Markdown -- these are read far more
/// often than they are written, and anything that does not render is worse
/// than plain text.
struct ReleaseNotesView: View {
    let text: String

    private enum Line: Identifiable {
        case heading(String), bullet(String), paragraph(String), gap
        var id: String {
            switch self {
            case .heading(let s): return "h" + s
            case .bullet(let s): return "b" + s
            case .paragraph(let s): return "p" + s
            case .gap: return "gap" + UUID().uuidString
            }
        }
    }

    private var lines: [Line] {
        text.components(separatedBy: .newlines).map { raw in
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { return .gap }
            if l.hasPrefix("#") {
                return .heading(l.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
            }
            if l.hasPrefix("- ") || l.hasPrefix("* ") {
                return .bullet(String(l.dropFirst(2)))
            }
            return .paragraph(l)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                switch line {
                case .heading(let s):
                    Text(s).font(.headline).padding(.top, 4)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{2022}")
                        Text(s).fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let s):
                    Text(s).fixedSize(horizontal: false, vertical: true)
                case .gap:
                    Spacer().frame(height: 4)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
final class WhatsNewWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: WhatsNewWindowController?

    static func present() {
        if let s = shared {
            s.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: WhatsNewView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "What\u{2019}s New in PowerEmu"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 460))
        window.center()
        let c = WhatsNewWindowController(window: window)
        window.delegate = c
        shared = c
        c.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called at every start: shows itself only the first time a newer
    /// PowerEmu than last time is opened, and only if there is something to
    /// say about it.
    static func presentIfJustUpdated() {
        guard Updater.justUpdated() else { return }
        guard Updater.notesForRunningBuild() != nil else { return }
        present()
    }

    func windowWillClose(_ notification: Notification) {
        WhatsNewWindowController.shared = nil
    }
}

struct WhatsNewView: View {
    @State private var history = Updater.history()
    @State private var fetching = false

    private var current: ReleaseNote? { Updater.notesForRunningBuild() }

    /// Only what came before this copy.  A copy that is behind will have
    /// newer releases in the list too, and calling those "earlier" is
    /// simply wrong -- offering them is the update window's job, not this
    /// one's.
    private var older: [ReleaseNote] {
        history.filter { $0.build < Updater.runningBuild }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.map { "PowerEmu \($0.version)" } ?? "PowerEmu \(Updater.runningVersion)")
                        .font(.title2).bold()
                    if let d = current?.published {
                        Text(d.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let c = current, !c.notes.isEmpty {
                        ReleaseNotesView(text: c.notes)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("There are no notes for this version yet.")
                                .foregroundStyle(.secondary)
                            if fetching {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Look Now") { refresh() }
                            }
                        }
                    }
                    if !older.isEmpty {
                        Divider()
                        Text("Earlier versions").font(.headline)
                        ForEach(older) { r in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(r.version).font(.subheadline).bold()
                                    if let d = r.published {
                                        Text(d.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if r.notes.isEmpty {
                                    Text("No notes.").font(.callout).foregroundStyle(.secondary)
                                } else {
                                    ReleaseNotesView(text: r.notes)
                                }
                            }
                            .padding(.bottom, 4)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .onAppear { if history.isEmpty { refresh() } }
    }

    /// The notes live with the feed, so there is nothing to show until it
    /// has been read once.  A copy that has never looked can look now.
    private func refresh() {
        fetching = true
        Task {
            _ = try? await Updater.check()
            await MainActor.run {
                history = Updater.history()
                fetching = false
            }
        }
    }
}
