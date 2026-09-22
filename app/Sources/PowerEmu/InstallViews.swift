import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Progress

/// Shown at the top of a machine's page while PowerEmu installs Mac OS X.
struct InstallProgressSection: View {
    @EnvironmentObject var library: VMLibrary
    @ObservedObject var session: InstallSession
    @State private var confirmStop = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(headline).font(.title3.bold())
                    Spacer()
                    if session.outcome == .running {
                        Text("\(Int(session.fraction * 100))%").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if session.outcome == .running || session.outcome == .finished {
                    ProgressView(value: session.fraction)
                        .progressViewStyle(.linear)
                    HStack {
                        Text(session.detail.isEmpty ? " " : session.detail)
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if session.outcome == .running {
                            Text(session.slow ? "Taking longer than usual…" : InstallSession.remainingText(session.remaining))
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                steps
                if let u = session.updateSource, session.outcome == .running {
                    Label(u, systemImage: u.contains("downloading") || u.contains("starting") ? "arrow.down.circle" : "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let f = session.failure {
                    Text(f).foregroundStyle(session.outcome == .cancelled ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if !session.guestLog.isEmpty, session.outcome == .failed {
                        DisclosureGroup("Details") {
                            ScrollView {
                                Text(session.guestLog).font(.caption.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 160)
                        }
                    }
                }
                if let n = session.note {
                    Label(n, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    if session.outcome == .running {
                        Button("Stop Installing…") { confirmStop = true }
                    } else if session.outcome != .finished {
                        Button("Dismiss") { library.dismissInstall(session.vm) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .confirmationDialog("Stop installing Mac OS X?", isPresented: $confirmStop) {
            Button("Stop Installing", role: .destructive) { session.cancel() }
        } message: {
            Text("The installation can’t be resumed; it would have to start again from the beginning.")
        }
    }

    private var headline: String {
        switch session.outcome {
        case .running: return session.title
        case .finished: return "Mac OS X is installed"
        case .failed: return "The installation didn’t finish"
        case .cancelled: return "Installation stopped"
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(session.steps) { step in
                HStack(spacing: 8) {
                    Group {
                        if step.id < session.stepIndex || session.outcome == .finished {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if step.id == session.stepIndex && session.outcome == .running {
                            ProgressView().controlSize(.small)
                        } else if step.id == session.stepIndex && session.outcome == .failed {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(step.title)
                        .foregroundStyle(step.id <= session.stepIndex || session.outcome == .finished ? .primary : .secondary)
                }
                .font(.callout)
            }
        }
    }
}
