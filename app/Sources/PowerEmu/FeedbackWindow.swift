import AppKit
import SwiftUI

/*
 * The feedback window.
 *
 * The order of the fields is from "Garden OSX/docs/ADDING-AN-APP.md" and is
 * deliberate: someone reporting a problem is already annoyed, and every field
 * they do not understand is a reason to give up. Topic first as a pop-up
 * (never free text), then one large box for what actually happened, then the
 * optional things.
 */

/// The things PowerEmu can disappoint someone with -- not a taxonomy of
/// software defects. Symptoms, not causes; the most common first; "A
/// suggestion" kept because a good share of what arrives is not a bug; and
/// "Something else" last as the honest escape hatch.
private let feedbackTopics = [
    "The guest will not start",
    "Graphics are wrong",
    "No sound",
    "A device is missing",
    "It was too slow",
    "It quit unexpectedly",
    "A suggestion",
    "Something else",
]

@MainActor
final class FeedbackWindowController: NSWindowController {
    private static var shared: FeedbackWindowController?

    static func present() {
        if let existing = shared, let w = existing.window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Snapshot before our own window covers anything.
        let shot = Feedback.windowSnapshot()
        let view = FeedbackView(snapshot: shot) { shared?.close(); shared = nil }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Send Feedback"
        window.styleMask = [.titled, .closable]
        window.center()
        let c = FeedbackWindowController(window: window)
        shared = c
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct FeedbackView: View {
    let snapshot: NSImage?
    let dismiss: () -> Void

    @State private var topic = feedbackTopics[0]
    @State private var summary = ""
    @State private var message = ""
    @State private var email = ""
    @State private var includeShot = true
    @State private var sending = false
    @State private var outcome: String?
    @State private var outcomeIsGood = false
    @FocusState private var messageFocused: Bool

    private let page = Feedback.currentPage()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("What is this about?", selection: $topic) {
                ForEach(feedbackTopics, id: \.self) { Text($0) }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("What happened?")
                TextEditor(text: $message)
                    .font(.body)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.35)))
                    .focused($messageFocused)
            }

            TextField("Short summary (optional)", text: $summary)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Your email (only if you want an answer)", text: $email)
                    .textContentType(.emailAddress)
            }

            if let snapshot {
                HStack(alignment: .top, spacing: 10) {
                    Toggle("Include a picture of PowerEmu's window", isOn: $includeShot)
                    Spacer()
                    // The live thumbnail is exactly what would be sent, at a
                    // size where you can recognise what is in it.
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 168, height: 105)
                        .border(Color.secondary.opacity(0.4))
                        .opacity(includeShot ? 1 : 0.3)
                }
            }

            // Everything else that travels, named, with its actual values.
            Text("Also sent: \(Feedback.disclosure())")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let outcome {
                Text(outcome)
                    .font(.callout)
                    .foregroundStyle(outcomeIsGood ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if sending { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { Task { await send() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || message.trimmingCharacters(in: .whitespacesAndNewlines).count < 5)
            }
        }
        .padding(18)
        .frame(width: 520, alignment: .leading)
        .onAppear { messageFocused = true }
    }

    private func send() async {
        sending = true
        outcome = nil
        var report = FeedbackReport(
            id: FeedbackReport.newID(),
            topic: topic,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            message: message,
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            page: page,
            system: Feedback.systemInfo(),
            screenshot: ""
        )
        if includeShot, let snapshot {
            report.screenshot = Feedback.pngBase64(snapshot)
        }

        switch await Feedback.send(report) {
        case .sent:
            outcomeIsGood = true
            outcome = "Thank you — that reached us."
            sending = false
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        case .deferred(let why):
            // Already queued by Feedback.send; say so plainly rather than
            // leaving someone thinking their words vanished.
            outcomeIsGood = false
            outcome = "Could not reach the server (\(why)). Your report is saved "
                    + "and will be sent the next time PowerEmu starts."
            sending = false
        case .refused(let why):
            outcomeIsGood = false
            outcome = "The server would not accept this report: \(why)"
            sending = false
        }
    }
}
