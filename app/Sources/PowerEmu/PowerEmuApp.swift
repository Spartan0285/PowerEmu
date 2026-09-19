import SwiftUI

@main
struct PowerEmuApp: App {
    @StateObject private var library = VMLibrary()

    var body: some Scene {
        WindowGroup("PowerEmu") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}
