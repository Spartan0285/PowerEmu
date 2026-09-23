import SwiftUI
import AppKit
import UniformTypeIdentifiers

/*
 * The Installation Assistant: making a new virtual Mac one decision at a
 * time. Each page has a title, an illustration, a paragraph saying what is
 * being decided and why, and the controls for that decision alone.
 *
 * The illustrations are placeholders drawn from SF Symbols inside a small
 * window frame. Custom artwork drops in through `Page.artwork`: an image of
 * that name in the app's resources replaces the symbol. (No Apple artwork:
 * PowerEmu doesn't ship Apple's.)
 */
struct NewMachineSheet: View {
    @EnvironmentObject var library: VMLibrary
    @Environment(\.dismiss) private var dismiss
    var initialDisc: URL? = nil
    var onDone: (VirtualMachine) -> Void

    enum Page: Int, CaseIterable {
        case disc, machine, about, options, update, summary

        /// Resource name of custom artwork for the page, if supplied.
        var artwork: String {
            switch self {
            case .disc: return "setup-disc"
            case .machine: return "setup-machine"
            case .about: return "setup-about"
            case .options: return "setup-options"
            case .update: return "setup-update"
            case .summary: return "setup-ready"
            }
        }

        var symbol: String {
            switch self {
            case .disc: return "opticaldisc"
            case .machine: return "internaldrive"
            case .about: return "info.circle"
            case .options: return "globe"
            case .update: return "arrow.down.app"
            case .summary: return "checkmark.seal"
            }
        }
    }

    @State private var page: Page = .disc
    @State private var name = "Tiger"
    @State private var memory = 2048
    @State private var vram = 128
    @State private var diskGB = 40
    @State private var disc: URL?
    @StateObject private var download = MediaDownload()
    @StateObject private var discCopy = DiscCopy()
    @ObservedObject private var drives = HostDriveMonitor.shared
    @State private var link = ""
    @State private var source: Source = .have
    enum Source: String, CaseIterable {
        case have = "Disc image", drive = "DVD in this Mac", link = "Download"
    }
    @State private var info: InstallPlan.DiscInfo?
    @State private var inspecting = false
    @State private var discProblem: String?
    /// "" = the same as this Mac.
    @State private var language = ""
    @State private var additionalLanguages = false
    @State private var printerDrivers = false
    @State private var additionalFonts = false
    @State private var update10411 = true
    @State private var model = MacModel.standard.id
    /// CPUConfig.id; nil = the model's usual one.
    @State private var cpuID: String?
    /// About This Mac shows the chosen Mac (true) or Tiger's Apple logo.
    @State private var aboutPicture = true
    @State private var showAdvanced = false
    @State private var showHelp = false
    @State private var dropTargeted = false
    @State private var error: String?

    // MARK: Derived

    private var hostLanguage: InstallPlan.Language { InstallPlan.hostLanguage }
    private var chosenLanguage: String { language.isEmpty ? hostLanguage.value : language }
    private var languageName: String {
        InstallPlan.languages.first { $0.value == chosenLanguage }?.name ?? chosenLanguage
    }
    private var automatic: Bool { info?.automatable == true }
    /// The update only applies to Tiger discs older than 10.4.11.
    private var updateApplies: Bool {
        guard let v = info?.version else { return false }
        return v.hasPrefix("10.4") && v != "10.4.11"
    }
    private var version: String { info.map { $0.version == "10.4" ? "10.4.0" : $0.version } ?? "10.4" }

    private func options(languages: Bool? = nil, printers: Bool? = nil, fonts: Bool? = nil) -> InstallPlan.Options? {
        guard let disc else { return nil }
        return InstallPlan.Options(disc: disc, diskGB: diskGB, language: chosenLanguage,
                                   additionalLanguages: languages ?? additionalLanguages,
                                   printerDrivers: printers ?? printerDrivers,
                                   additionalFonts: fonts ?? additionalFonts,
                                   update10411: update10411 && updateApplies)
    }

    private func installedKB(_ o: InstallPlan.Options?) -> Int {
        guard let info, let o else { return 0 }
        return info.packages(o).reduce(0) { $0 + $1.kb }
    }

    /// What turning an option on adds, e.g. "+1.3 GB".
    private func extra(languages: Bool? = nil, printers: Bool? = nil, fonts: Bool? = nil) -> String {
        let base = installedKB(options(languages: false, printers: false, fonts: false))
        let with = installedKB(options(languages: languages ?? false, printers: printers ?? false, fonts: fonts ?? false))
        let d = max(with - base, 0)
        return d >= 1_048_576 ? String(format: "+%.1f GB", Double(d) / 1_048_576) : "+\(d / 1024) MB"
    }

    private var estimateSeconds: Double? {
        guard automatic, let o = options() else { return nil }
        return InstallTiming.total(expectedKB: installedKB(o), update: o.update10411, from: info?.version ?? "10.4")
    }

    /// The pages this disc needs: no update page for a 10.4.11 disc, and
    /// only the disc and the machine for one PowerEmu can't drive.
    private var pages: [Page] {
        guard automatic else { return [.disc, .machine] }
        return Page.allCases.filter { $0 != .update || updateApplies }
    }

    private var isLast: Bool { page == pages.last }

    private var chosenModel: MacModel { MacModel.named(model) ?? .standard }
    private var cpu: CPUConfig { chosenModel.cpus.first { $0.id == cpuID } ?? chosenModel.defaultCPU }
    private var shownVersion: String { update10411 && updateApplies ? "10.4.11" : version }

    private var personalize: InstallPlan.Personalize {
        InstallPlan.Personalize(processorText: cpu.dual ? cpu.aboutText : nil,
                                modelName: chosenModel.profilerName,
                                aboutImage: aboutPicture ? AboutBoxImage.tiff(for: chosenModel) : nil)
    }

    private var canContinue: Bool {
        switch page {
        case .disc: return disc != nil && !inspecting && info != nil
        case .machine: return !name.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    // MARK: Layout

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                backdrop
                VStack(spacing: 18) {
                    Text(title)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.top, 26)
                    Rectangle().fill(.white.opacity(0.18)).frame(width: 420, height: 1)
                    HStack(alignment: .center, spacing: 36) {
                        illustration
                        // Scrolls when a page grows (Advanced opened): the
                        // title and the buttons below never move.
                        ScrollViewReader { scroller in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(explanation)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                controls
                                Color.clear.frame(height: 1).id("page-end")
                            }
                            .frame(width: 350, alignment: .leading)
                            .padding(.vertical, 8)
                            .frame(minHeight: 350, alignment: .center)
                        }
                        .scrollIndicators(.automatic)
                        .frame(width: 366)
                        .onChange(of: showAdvanced) { _, open in
                            // Bring the rows that just appeared into view.
                            if open {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    withAnimation { scroller.scrollTo("page-end", anchor: .bottom) }
                                }
                            }
                        }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 14)
                }
            }
            .frame(height: 478)
            .clipped()
            bottomBar
        }
        .frame(width: 800, height: 540)
        .environment(\.colorScheme, .dark)
        .onAppear { if let d = initialDisc, disc == nil { use(d) } }
    }

    private var backdrop: some View {
        LinearGradient(colors: [Color(red: 0.07, green: 0.12, blue: 0.24), Color(red: 0.10, green: 0.22, blue: 0.40),
                                Color(red: 0.05, green: 0.09, blue: 0.18)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(
                RadialGradient(colors: [Color(red: 0.35, green: 0.62, blue: 0.95).opacity(0.25), .clear],
                               center: .init(x: 0.3, y: 0.55), startRadius: 10, endRadius: 420))
    }

    @ViewBuilder private var illustration: some View {
        if page == .about {
            AboutMock(image: aboutPicture ? chosenModel.image : nil, version: shownVersion,
                      processor: cpu.aboutText, memoryMB: memory)
        } else {
            windowIllustration
        }
    }

    /// A little window with the page's picture in it.
    private var windowIllustration: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 7, height: 7) }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(Color(white: 0.28))
            ZStack {
                LinearGradient(colors: [Color(red: 0.36, green: 0.66, blue: 0.98), Color(red: 0.10, green: 0.36, blue: 0.80)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let img = NSImage(named: page.artwork) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else if let icon = pageIcon {
                    Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                        .frame(width: 150, height: 150)
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
                } else {
                    Image(systemName: page.symbol)
                        .font(.system(size: 84, weight: .thin))
                        .foregroundStyle(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                }
            }
        }
        .frame(width: 300, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }

    /// A real picture for the page when there is one: the disc's own
    /// installer icon once a Tiger disc is recognised, the chosen Mac.
    private var pageIcon: NSImage? {
        switch page {
        case .disc: return automatic ? DiscIcons.installDiscImage : nil
        case .machine, .summary: return MacModel.named(model)?.image
        default: return nil
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { showHelp.toggle() } label: {
                Image(systemName: "questionmark").font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(white: 0.32)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showHelp, arrowEdge: .top) {
                Text(help).font(.callout).padding(14).frame(width: 300).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach(pages, id: \.self) { p in
                    Circle().fill(p == page ? Color.white : Color.white.opacity(0.25)).frame(width: 6, height: 6)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            if page == pages.first {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            } else {
                Button("Back") { move(-1) }.keyboardShortcut(.cancelAction)
            }
            Button(isLast ? (automatic ? "Install" : "Create") : "Continue") {
                if isLast { create() } else { move(1) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue)
        }
        .controlSize(.large)
        .padding(.horizontal, 18)
        .frame(height: 62)
        .background(Color(white: 0.17))
    }

    private func move(_ d: Int) {
        guard let i = pages.firstIndex(of: page) else { return }
        let j = min(max(i + d, 0), pages.count - 1)
        withAnimation(.easeInOut(duration: 0.18)) { page = pages[j] }
    }

    // MARK: Words

    private var title: String {
        switch page {
        case .disc: return "Install Mac OS X"
        case .machine: return "Your Virtual Mac"
        case .about: return "About This Mac"
        case .options: return "Choose What to Install"
        case .update: return "Update to Mac OS X 10.4.11"
        case .summary: return "Ready to Install"
        }
    }

    private var explanation: String {
        switch page {
        case .disc:
            return "PowerEmu installs Mac OS X for you from your own install disc. Choose the disc image of a Mac OS X 10.4 Tiger install DVD for PowerPC Macs, or drag it here."
        case .machine:
            return "Name your virtual Mac, choose the Mac it looks like, and give it a hard disk. Mac OS X sees the size you pick here, while the disk takes up space on your Mac only as it fills \u{2014} so pick a roomy one. It can be made larger later, but not smaller."
        case .about:
            return "Choose how your virtual Mac describes itself in About This Mac and System Profiler. This is for looks only: it runs the same emulated Power Mac G4 at the same speed whatever you pick, and “Dual” doesn’t add a second processor."
        case .options:
            return "Mac OS X comes with extras most people never use. Leaving them out makes the install smaller and quicker, and you can add them later from the same disc."
        case .update:
            return "Mac OS X 10.4.11 is the last and most reliable version of Tiger. PowerEmu can add it before your virtual Mac starts for the first time, so it’s ready to use straight away."
        case .summary:
            return "PowerEmu will install Mac OS X by itself. You can keep using your Mac; the virtual Mac opens at Setup Assistant when it’s ready."
        }
    }

    private var help: String {
        switch page {
        case .disc:
            return "Any Mac OS X 10.4 install DVD for PowerPC Macs works, as an .iso, .dmg, .cdr or .toast image. PowerEmu never changes your image: it works on a copy that is deleted afterwards."
        case .machine:
            return "40 GB is plenty for Tiger and years of software. Memory and graphics are set to what works best; change them later in the virtual Mac’s settings if you like."
        case .about:
            return "The speeds are the ones Apple sold for the Mac you chose. PowerEmu changes only what Mac OS X displays: the processor line and picture in About This Mac, and the Machine Name in System Profiler. Your originals are kept."
        case .options:
            return "The language is the one Mac OS X uses for its menus and windows. Additional languages are other translations of the whole system; printer drivers are for real printers; additional fonts are mostly for other alphabets."
        case .update:
            return "The update is Apple’s free Mac OS X 10.4.11 Combo Update, downloaded directly from Apple and checked against Apple’s published checksum. PowerEmu doesn’t include any Apple software."
        case .summary:
            return "You can follow the installation on the virtual Mac’s page. Stopping it part-way means starting again from the beginning."
        }
    }

    // MARK: Controls, per page

    @ViewBuilder private var controls: some View {
        switch page {
        case .disc: discControls
        case .machine: machineControls
        case .about: aboutControls
        case .options: optionsControls
        case .update: updateControls
        case .summary: summaryControls
        }
    }

    private var discControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch source {
            case .have:  haveDiscControls
            case .drive: driveControls
            case .link:  linkControls
            }
            if inspecting {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading the disc…") }
                    .font(.callout).foregroundStyle(.secondary)
            } else if let info {
                Label(info.automatable ? "Mac OS X \(version) install DVD — PowerEmu can install this for you."
                                       : "Mac OS X \(version). PowerEmu can’t drive this disc’s installer, so it will start it for you to use.",
                      systemImage: info.automatable ? "checkmark.circle.fill" : "info.circle")
                    .font(.callout).foregroundStyle(info.automatable ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let discProblem {
                Label(discProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A link the reader gives us: PowerEmu suggests none of its own, since
    /// nobody may pass Mac OS X around but Apple.
    private var linkControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("https://…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .disabled(download.running)
                    .onSubmit { if !link.isEmpty { download.start(link: link) } }
                if download.running {
                    Button("Stop") { download.cancel() }
                } else {
                    Button("Get") { download.start(link: link) }
                        .disabled(link.isEmpty)
                }
            }
            if download.running {
                VStack(alignment: .leading, spacing: 4) {
                    if let f = download.fraction {
                        ProgressView(value: f)
                    } else {
                        ProgressView()
                    }
                    Text(download.progressText).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let p = download.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !MediaDownload.remembered.isEmpty && !download.running {
                Menu("Links you have used") {
                    ForEach(MediaDownload.remembered, id: \.self) { old in
                        Button(old) { link = old; download.start(link: old) }
                    }
                }
                .font(.caption)
            }
            Text("Paste a link to a Mac OS X install disc image. PowerEmu keeps it, so a second virtual Mac doesn’t download it again. Only take Mac OS X from somewhere you are entitled to.")
                .font(.caption).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: download.file) { _, new in
            if let new { use(new) }
        }
    }

    /// A real disc in this Mac's drive.  It is copied to an image first,
    /// because installing without anyone watching means patching a copy of
    /// the disc, and a pressed DVD cannot be patched.
    private var driveControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            let optical = drives.drives.filter { $0.kind != .floppy }
            if optical.isEmpty {
                Label("Put a Mac OS X disc in this Mac’s drive.", systemImage: "opticaldiscdrive")
                    .font(.callout).foregroundStyle(.white.opacity(0.8))
            } else {
                ForEach(optical) { d in
                    HStack {
                        Image(systemName: "opticaldisc").foregroundStyle(.white.opacity(0.8))
                        Text(d.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Use This Disc") { discCopy.start(d) }
                            .disabled(discCopy.running)
                    }
                    .font(.callout)
                }
            }
            if discCopy.running {
                VStack(alignment: .leading, spacing: 4) {
                    if let f = discCopy.fraction { ProgressView(value: f) } else { ProgressView() }
                    HStack {
                        Text("Copying the disc… \(discCopy.progressText)")
                        Spacer()
                        Button("Stop") { discCopy.cancel() }.controlSize(.small)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let p = discCopy.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("The disc is copied to this Mac once, so PowerEmu can install Mac OS X without anyone watching. macOS will ask for an administrator to read the disc.")
                .font(.caption).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: discCopy.file) { _, new in
            if let new { use(new) }
        }
    }

    private var haveDiscControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { chooseDisc() } label: {
                HStack(spacing: 10) {
                    Image(systemName: disc == nil ? "square.and.arrow.down" : "opticaldisc")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(disc?.lastPathComponent ?? "Choose Disc Image…").font(.headline).lineLimit(1).truncationMode(.middle)
                        Text(disc == nil ? "or drag it here" : "Click to choose a different one")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(dropTargeted ? 0.22 : 0.10)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: disc == nil ? [5, 4] : [])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in use(url) } }
                }
                return true
            }
        }
    }

    private var machineControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Name") {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            LabeledContent {
                Picker("", selection: $diskGB) {
                    ForEach([10, 20, 40, 80, 120], id: \.self) { Text("\($0) GB").tag($0) }
                }
                .labelsHidden().frame(width: 200)
            } label: {
                HStack(spacing: 6) {
                    if let hd = DiscIcons.hardDiskImage { Image(nsImage: hd).resizable().frame(width: 18, height: 18) }
                    Text("Hard disk")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Looks like").font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 6), count: 6), spacing: 6) {
                    ForEach(MacModel.all) { m in
                        Button { model = m.id; cpuID = nil } label: {
                            Group {
                                if let img = m.image {
                                    Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                                } else {
                                    Image(systemName: m.symbol).font(.title2)
                                }
                            }
                            .frame(width: 40, height: 40)
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(model == m.id ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(model == m.id ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help(m.name)
                    }
                }
                Text(MacModel.named(model)?.name ?? "").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Memory") {
                        Picker("", selection: $memory) {
                            ForEach([512, 1024, 1536, 2048], id: \.self) { Text($0 >= 1024 ? "\($0 / 1024) GB" : "\($0) MB").tag($0) }
                        }
                        .labelsHidden().frame(width: 200)
                    }
                    LabeledContent("Video memory") {
                        Picker("", selection: $vram) {
                            ForEach(VMConfig.vramChoices, id: \.self) { Text("\($0) MB").tag($0) }
                        }
                        .labelsHidden().frame(width: 200)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private var aboutControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Processor") {
                Picker("", selection: Binding(get: { cpu.id }, set: { cpuID = $0 })) {
                    ForEach(chosenModel.cpus) { c in Text(c.label).tag(c.id) }
                }
                .labelsHidden().frame(width: 200)
            }
            LabeledContent("Picture") {
                Picker("", selection: $aboutPicture) {
                    Text("This Mac").tag(true)
                    Text("Apple logo").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            Label("Cosmetic only: no effect on speed", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var optionsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Language") {
                Picker("", selection: $language) {
                    Text("Same as this Mac (\(hostLanguage.name))").tag("")
                    Divider()
                    ForEach(InstallPlan.languages, id: \.value) { Text($0.name).tag($0.value) }
                }
                .labelsHidden().frame(width: 210)
            }
            Divider().opacity(0.4)
            optionToggle("Additional languages", extra(languages: true), $additionalLanguages)
            optionToggle("Printer drivers", extra(printers: true), $printerDrivers)
            optionToggle("Additional fonts", extra(fonts: true), $additionalFonts)
        }
    }

    private func optionToggle(_ label: String, _ size: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            HStack {
                Text(label)
                Spacer()
                Text(size).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    private var updateControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                reason("Two years of Apple’s fixes for stability and security")
                reason("Needed by later Tiger software, like Safari 4 and iTunes 9")
                reason("PowerEmu’s accelerated graphics are built and tested on it")
            }
            .font(.callout)
            choice(on: true, title: "Update to 10.4.11", badge: "Recommended",
                   detail: InstallPlan.existingCombo != nil
                       ? "Uses Apple’s update already on this Mac."
                       : "Downloads Apple’s free update (181 MB) while Mac OS X installs.")
            choice(on: false, title: "Keep Mac OS X \(version)", badge: nil,
                   detail: "You can update later with Apple’s combo updater.")
        }
    }

    private func reason(_ text: String) -> some View {
        Label { Text(text).foregroundStyle(.white.opacity(0.9)) } icon: {
            Image(systemName: "checkmark").foregroundStyle(.green)
        }
    }

    private func choice(on value: Bool, title: String, badge: String?, detail: String) -> some View {
        Button { update10411 = value } label: {
            HStack(spacing: 10) {
                Image(systemName: update10411 == value ? "largecircle.fill.circle" : "circle")
                    .font(.title3).foregroundStyle(update10411 == value ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        if let badge {
                            Text(badge).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.3)))
                        }
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(update10411 == value ? 0.14 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var summaryControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            summaryRow("opticaldisc", "Mac OS X \(version)" + (update10411 && updateApplies ? ", updated to 10.4.11" : ""))
            summaryRow("internaldrive", "“\(name)”, \(MacModel.named(model)?.name ?? "Power Mac G4"), \(diskGB) GB hard disk")
            summaryRow("cpu", cpu.label + " PowerPC G4 (shown only)")
            summaryRow("globe", languageName + (additionalLanguages ? " and other languages" : ""))
            let extras = [printerDrivers ? "printer drivers" : nil, additionalFonts ? "additional fonts" : nil].compactMap { $0 }
            summaryRow("shippingbox", extras.isEmpty ? "No printer drivers or extra fonts" : "With " + extras.joined(separator: " and "))
            if let s = estimateSeconds {
                summaryRow("clock", "\(InstallSession.durationText(s).prefix(1).uppercased() + InstallSession.durationText(s).dropFirst()) on this Mac, \(InstallSession.gb(installedKB(options()))) installed")
                    .padding(.top, 4)
            }
        }
        .font(.callout)
    }

    private func summaryRow(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).foregroundStyle(.white.opacity(0.92)) } icon: {
            Image(systemName: symbol).foregroundStyle(.white.opacity(0.7)).frame(width: 18)
        }
    }

    // MARK: Actions

    private func chooseDisc() {
        let p = NSOpenPanel()
        p.allowedContentTypes = VMConfig.discExtensions.compactMap { UTType(filenameExtension: $0) }
        p.message = "Choose a Mac OS X install disc image"
        guard p.runModal() == .OK, let u = p.url else { return }
        use(u)
    }

    private func use(_ u: URL) {
        guard VMConfig.discExtensions.contains(u.pathExtension.lowercased()) else {
            discProblem = "That isn’t a disc image. Choose an .iso, .dmg, .cdr or .toast file."
            return
        }
        disc = u
        info = nil
        discProblem = nil
        inspecting = true
        Task.detached {
            let result = Result { try InstallPlan.inspect(u) }
            await MainActor.run {
                inspecting = false
                switch result {
                case .success(let i) where !i.version.hasPrefix("10.4"):
                    discProblem = "This is a Mac OS X \(i.version) disc. PowerEmu installs Mac OS X 10.4 Tiger; other versions aren’t supported yet."
                case .success(let i):
                    info = i
                    let major = i.version.split(separator: ".").prefix(2).joined(separator: ".")
                    if name == "Tiger" || name.isEmpty { name = major == "10.4" ? "Tiger" : "Mac OS X \(major)" }
                    // Developer testing: POWEREMU_TEST_SETUP_PAGE=n opens at page n.
                    if let n = ProcessInfo.processInfo.environment["POWEREMU_TEST_SETUP_PAGE"].flatMap(Int.init),
                       n < pages.count { page = pages[n] }
                    if ProcessInfo.processInfo.environment["POWEREMU_TEST_SETUP_ADVANCED"] != nil { showAdvanced = true }
                case .failure(let e):
                    discProblem = e.localizedDescription
                }
            }
        }
    }

    private func create() {
        error = nil
        do {
            let vm: VirtualMachine
            if automatic, var o = options(), let info {
                o.personalize = personalize
                vm = try library.installMachine(name: name, memoryMB: memory, vramMB: vram, options: o,
                                                discVersion: info.version)
            } else {
                // A disc PowerEmu can't drive: start its own installer, as before.
                vm = try library.newMachine(name: name, osName: "Mac OS X 10.4 Tiger", memoryMB: memory,
                                            vramMB: vram, diskGB: diskGB, installDisc: disc)
            }
            vm.config.model = model
            vm.config.cpuMHz = cpu.mhz
            try? vm.save()
            onDone(vm)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A small copy of Tiger's About This Mac, showing what the reader chose.
struct AboutMock: View {
    let image: NSImage?
    let version: String
    let processor: String
    let memoryMB: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 7, height: 7) }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
            VStack(spacing: 4) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: "applelogo").resizable().scaledToFit().padding(6)
                            .foregroundStyle(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.5)], startPoint: .top, endPoint: .bottom))
                    }
                }
                .frame(width: 70, height: 70)
                Text("Mac OS X").font(.system(size: 17, weight: .bold)).foregroundStyle(Color(white: 0.12))
                Text("Version \(version)").font(.system(size: 10)).foregroundStyle(Color(white: 0.35))
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    row("Processor", processor)
                    row("Memory", memoryMB >= 1024 ? "\(memoryMB / 1024) GB DDR SDRAM" : "\(memoryMB) MB DDR SDRAM")
                    row("Startup Disk", "Macintosh HD")
                }
                .font(.system(size: 10))
                .padding(.top, 6)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.93))
        }
        .frame(width: 300, height: 250)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .environment(\.colorScheme, .light)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).bold().foregroundStyle(Color(white: 0.2)).gridColumnAlignment(.trailing)
            Text(value).foregroundStyle(Color(white: 0.2))
        }
    }
}
