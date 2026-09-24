//  UpdateWindow.swift
//  What the reader sees when there is a newer PowerEmu.

import SwiftUI
import AppKit

@MainActor
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: UpdateWindowController?

    static func present(_ update: AppUpdate, library: VMLibrary? = nil) {
        if let s = shared {
            s.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = UpdateModel(update: update, library: library)
        let hosting = NSHostingController(rootView: UpdateView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "PowerEmu \(update.version)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        let c = UpdateWindowController(window: window)
        window.delegate = c
        shared = c
        c.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Asked for from the menu: say so even when there is nothing new,
    /// because silence looks like a failure.
    static func checkNow(library: VMLibrary?) {
        Task {
            do {
                if let u = try await Updater.check() {
                    present(u, library: library)
                } else {
                    let a = NSAlert()
                    a.messageText = "PowerEmu is up to date"
                    a.informativeText = "This is version \(Updater.runningVersion) (\(Updater.runningBuild))."
                    a.runModal()
                }
            } catch {
                let a = NSAlert()
                a.messageText = "PowerEmu could not check for updates"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        UpdateWindowController.shared = nil
    }
}

@MainActor
final class UpdateModel: ObservableObject {
    let update: AppUpdate
    weak var library: VMLibrary?
    @Published var progress: Double?
    @Published var problem: String?
    @Published var installing = false

    init(update: AppUpdate, library: VMLibrary?) {
        self.update = update
        self.library = library
    }

    func install() {
        problem = nil
        progress = 0
        installing = true
        let u = update
        Task { [weak self] in
            do {
                let zip = try await Updater.download(u) { p in
                    Task { @MainActor [weak self] in self?.progress = p }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    do {
                        _ = try Updater.install(zip, library: self.library)
                    } catch {
                        self.problem = error.localizedDescription
                        self.installing = false
                        self.progress = nil
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.problem = error.localizedDescription
                    self?.installing = false
                    self?.progress = nil
                }
            }
        }
    }
}

struct UpdateView: View {
    @ObservedObject var model: UpdateModel

    private var update: AppUpdate { model.update }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PowerEmu \(update.version) is available")
                        .font(.headline)
                    Text("You have \(Updater.runningVersion) (\(Updater.runningBuild)).")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let d = update.published {
                        Text(d.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !update.notes.isEmpty {
                ScrollView {
                    Text(update.notes)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 170)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }
            if !update.runsHere, let m = update.minimumSystem {
                Label("This version needs macOS \(m) or later.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let p = model.progress {
                ProgressView(value: p) {
                    Text(p < 1 ? "Downloading\u{2026}" : "Installing\u{2026}")
                }
            }
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Skip This Version") {
                    Updater.skip(update)
                    model.library?.objectWillChange.send()
                    NSApp.keyWindow?.close()
                }
                .disabled(model.installing)
                Spacer()
                Button("Later") { NSApp.keyWindow?.close() }
                    .disabled(model.installing)
                Button("Install and Restart") { model.install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.installing || !update.runsHere)
            }
            Text("PowerEmu closes and opens again to finish. Virtual Macs must be shut down or asleep first.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 470)
    }
}
