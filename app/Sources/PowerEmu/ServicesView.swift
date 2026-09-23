import SwiftUI
import AppKit

/// The Web Accelerator's switches, pairing code and what it has done.
private struct WebAcceleratorSection: View {
    @ObservedObject var hub = ServicesHub.shared
    @State private var stats = WebAccelerator.Stats()
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            Toggle("Web Accelerator", isOn: Binding(get: { hub.config.webEnabled }, set: { hub.setWebEnabled($0) }))
            Group {
                Toggle("Convert images old Macs can’t show, and shrink huge ones",
                       isOn: Binding(get: { hub.config.webConvertImages }, set: { hub.setWebConvertImages($0) }))
                Toggle("Block ads and trackers",
                       isOn: Binding(get: { hub.config.webBlockTrackers }, set: { hub.setWebBlockTrackers($0) }))
                HStack {
                    Text("Pairing code for other Macs")
                    Spacer()
                    Text(hub.config.pairingCode).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .opacity(hub.config.allowNetwork ? 1 : 0.4)
                    Button("New Code") { hub.newPairingCode() }.controlSize(.small)
                }
                Text("\(stats.requests) requests · \(stats.converted) images converted · \(stats.blocked) blocked · \(ByteCountFormatter.string(fromByteCount: stats.bytesSaved, countStyle: .file)) saved")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!hub.config.webEnabled)
        } header: {
            Text("Web Accelerator")
        } footer: {
            Text("Captain Polliwog fetches web pages through PowerEmu when it finds it: this Mac does the secure connections, converts images, and leaves out ads. The old Mac still draws the page itself. Without PowerEmu, it connects on its own as before.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onReceive(tick) { _ in stats = hub.web.currentStats }
        .onAppear { stats = hub.web.currentStats }
    }
}

/// PowerMusic: this Mac holds the music and plays it; old Macs search and
/// control it.
private struct MusicSection: View {
    @ObservedObject var hub = ServicesHub.shared
    @State private var team = ""
    @State private var key = ""
    @State private var keyPath = ""
    @State private var storefront = ""

    private var keyReady: Bool {
        !hub.config.musicTeamID.isEmpty && !hub.config.musicKeyID.isEmpty
            && FileManager.default.fileExists(atPath: hub.config.musicKeyPath)
    }
    private var pagesReady: Bool {
        FileManager.default.fileExists(atPath: hub.config.musicWebRoot + "/index.html")
    }

    var body: some View {
        Section {
            Toggle("Music", isOn: Binding(get: { hub.config.musicEnabled }, set: { hub.setMusicEnabled($0) }))
            Group {
                if !keyReady {
                    Label("Needs an Apple Music key before it can answer anything",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if !pagesReady {
                    Label("The controller and player pages are not where PowerEmu is looking",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    HStack {
                        Label("Playing from this Mac", systemImage: "music.note.house")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Open Player") {
                            if let u = URL(string: hub.musicPlayerURL) { NSWorkspace.shared.open(u) }
                        }
                        .controlSize(.small)
                    }
                    HStack {
                        Text("On old Macs")
                        Spacer()
                        Text(ServicesHub.musicControllerURL(hub.config.musicPort))
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .opacity(hub.config.allowNetwork ? 1 : 0.4)
                    }
                }
                LabeledContent("Team ID") {
                    TextField("", text: $team, prompt: Text("ABCDE12345")).frame(width: 160)
                }
                LabeledContent("Key ID") {
                    TextField("", text: $key, prompt: Text("ABCDE12345")).frame(width: 160)
                }
                LabeledContent("Storefront") {
                    TextField("", text: $storefront, prompt: Text("us")).frame(width: 60)
                }
                HStack {
                    Text("Private key")
                    Spacer()
                    Text(keyPath.isEmpty ? "None chosen" : (keyPath as NSString).lastPathComponent)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.message = "Choose the MusicKit private key downloaded from the Apple Developer portal."
                        p.allowedFileTypes = ["p8"]
                        if p.runModal() == .OK, let u = p.url { keyPath = u.path; apply() }
                    }
                    .controlSize(.small)
                }
                HStack {
                    Spacer()
                    Button("Apply") { apply() }
                        .disabled(team.isEmpty || key.isEmpty || keyPath.isEmpty)
                }
            }
            .disabled(!hub.config.musicEnabled)
        } header: {
            Text("Music")
        } footer: {
            Text("PowerEmu holds the queue and searches Apple Music for old Macs that could never speak to Apple themselves. The music is played by a page on this Mac — Open Player, and leave it open — because Apple’s music can only be decrypted here; send the sound where you like, including to an AirPlay speaker. Virtual Macs reach it at 10.0.2.100:\(hub.config.musicPort); real Macs need “Let other Macs on the network use the Service Hub” above. The key is yours, from the Apple Developer portal, and stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            team = hub.config.musicTeamID
            key = hub.config.musicKeyID
            keyPath = hub.config.musicKeyPath
            storefront = hub.config.musicStorefront
        }
    }

    private func apply() {
        hub.setMusicKey(team: team, key: key, path: keyPath, storefront: storefront)
    }
}

/// The Service Hub window: the mail proxy's accounts and the settings to
/// type into Mail on an old Mac.
struct ServicesView: View {
    @ObservedObject var hub = ServicesHub.shared
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                Toggle("Let other Macs on the network use the Service Hub", isOn: Binding(get: { hub.config.allowNetwork },
                                                                                        set: { hub.setAllowNetwork($0) }))
            } header: {
                Text("Network")
            } footer: {
                Text("Virtual Macs always reach the Service Hub at 10.0.2.100. Real PowerPC Macs need this on. What passes between them and this Mac is not encrypted, so only allow it on a network you trust.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Mail proxy", isOn: Binding(get: { hub.config.mailEnabled }, set: { hub.setMailEnabled($0) }))
            } header: {
                Text("Mail")
            } footer: {
                Text("Old versions of Mail can’t use today’s secure connections. They connect to PowerEmu without SSL and sign in with a password PowerEmu makes up; PowerEmu signs in to your provider securely and passes the mail through. Your real password never leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            WebAcceleratorSection()

            MusicSection()

            Section {
                ForEach(hub.config.accounts) { a in
                    AccountRow(account: a)
                }
                if hub.config.accounts.isEmpty {
                    Text("No accounts").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Accounts")
                    Spacer()
                    Button("Add Account…") { adding = true }.controlSize(.small)
                }
            }

            if !hub.log.isEmpty {
                Section("Activity") {
                    ScrollView {
                        Text(hub.log.suffix(40).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 120)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 480)
        .sheet(isPresented: $adding) { AddAccountSheet() }
    }
}

private struct AccountRow: View {
    let account: MailAccount
    @ObservedObject var hub = ServicesHub.shared
    @State private var expanded = true
    @State private var confirmRemove = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if hub.passwordsLocked(account) {
                    Label("This copy of PowerEmu can’t read the passwords saved for this account: the Keychain trusts the copy that saved them. Remove the account and add it again.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
                Text("In Mail on the old Mac, add an account with these settings (Use SSL: off, Authentication: Password):")
                    .font(.callout).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                        Text("Virtual Macs").font(.caption.bold())
                        Text("Other Macs").font(.caption.bold()).opacity(hub.config.allowNetwork ? 1 : 0.4)
                    }
                    GridRow {
                        Text("Incoming (IMAP)").foregroundStyle(.secondary)
                        Text("10.0.2.100")
                        Text("\(ServicesHub.hostName) port \(String(ServicesHub.networkIMAPPort))").opacity(hub.config.allowNetwork ? 1 : 0.4)
                    }
                    GridRow {
                        Text("Outgoing (SMTP)").foregroundStyle(.secondary)
                        Text("10.0.2.100")
                        Text("\(ServicesHub.hostName) port \(String(ServicesHub.networkSMTPPort))").opacity(hub.config.allowNetwork ? 1 : 0.4)
                    }
                    GridRow {
                        Text("User name").foregroundStyle(.secondary)
                        Text(account.localUser).textSelection(.enabled)
                        Text("")
                    }
                    GridRow {
                        Text("Password").foregroundStyle(.secondary)
                        HStack {
                            Text(hub.localPassword(account)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(hub.localPassword(account), forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Copy (virtual Macs with PowerEmu Tools can paste it)")
                        }
                        Text("")
                    }
                }
                .font(.callout)
                HStack {
                    Button("New Password") { hub.newLocalPassword(account) }
                        .help("Make a new PowerEmu password; old Macs using the old one will be asked again")
                    Spacer()
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                }
                .controlSize(.small)
            }
            .padding(.vertical, 6)
        } label: {
            HStack {
                Image(systemName: "envelope")
                VStack(alignment: .leading) {
                    Text(account.email)
                    Text("\(account.provider.title) · \(account.imapHost)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Remove \(account.email) from PowerEmu?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { hub.remove(account) }
        } message: {
            Text("Old Macs will no longer be able to use it through PowerEmu. Nothing changes at \(account.provider.title).")
        }
    }
}

private struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = MailAccount.Provider.icloud
    @State private var email = ""
    @State private var password = ""
    @State private var login = ""
    @State private var imapHost = ""
    @State private var imapPort = 993
    @State private var smtpHost = ""
    @State private var smtpPort = 465
    @State private var smtpSecurity = MailAccount.Security.tls
    @State private var checking = false
    @State private var problem: String?

    private var account: MailAccount {
        var a = MailAccount.preset(provider, email: email.trimmingCharacters(in: .whitespaces))
        if provider == .other {
            a.imapHost = imapHost; a.imapPort = imapPort
            a.smtpHost = smtpHost; a.smtpPort = smtpPort; a.smtpSecurity = smtpSecurity
        }
        if !login.isEmpty { a.login = login }
        return a
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Mail Account").font(.title2.bold())
            Form {
                Picker("Provider", selection: $provider) {
                    ForEach(MailAccount.Provider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Email address", text: $email)
                SecureField("App-specific password", text: $password)
                Text(provider.passwordHelp).font(.caption).foregroundStyle(.secondary)
                if provider == .other {
                    TextField("Sign-in name (if not the address)", text: $login)
                    HStack {
                        TextField("IMAP server", text: $imapHost)
                        TextField("Port", value: $imapPort, format: .number.grouping(.never)).frame(width: 70)
                    }
                    HStack {
                        TextField("SMTP server", text: $smtpHost)
                        TextField("Port", value: $smtpPort, format: .number.grouping(.never)).frame(width: 70)
                    }
                    Picker("SMTP security", selection: $smtpSecurity) {
                        Text("SSL/TLS").tag(MailAccount.Security.tls)
                        Text("STARTTLS").tag(MailAccount.Security.starttls)
                    }.pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
            if let problem {
                Text(problem).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            HStack {
                if checking { ProgressView().controlSize(.small); Text("Signing in…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if problem != nil && !checking {
                    Button("Add Anyway") { save() }
                }
                Button("Add") { check() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || !email.contains("@") || password.isEmpty ||
                              (provider == .other && (imapHost.isEmpty || smtpHost.isEmpty)))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @State private var checked: MailAccount?

    private func check() {
        checking = true
        problem = nil
        let a = account, pw = MailAccountCheck.clean(password)
        Task {
            let (found, result) = await MailAccountCheck.run(a, password: pw)
            checking = false
            checked = found
            if let result { problem = result } else { save() }
        }
    }

    private func save() {
        // The checked account, unless the address was changed since.
        let a = checked.flatMap { $0.email == account.email && $0.imapHost == account.imapHost ? $0 : nil } ?? account
        ServicesHub.shared.add(a, providerPassword: MailAccountCheck.clean(password))
        dismiss()
    }
}
