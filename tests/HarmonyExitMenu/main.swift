import AppKit
func harmonyDebug(_ text: String) {}
MainActor.assumeIsolated {
let app = NSApplication.shared
app.mainMenu = NSMenu(title: "Fixture")
let bar = HarmonyMenuBar()
var exits = 0
bar.exitHarmony = { exits += 1 }
bar.setGuestWindowFocused(true)
bar.setMenuBar(pid: 123, app: "Fixture", tops: [(index: 1, title: "File")])
guard let item = app.mainMenu?.item(at: 0)?.submenu?.item(at: 0), let action = item.action else { fatalError("missing exit menu") }
precondition(item.title == "Exit Harmony" && item.target === bar)
precondition((item.target as? NSObject)?.responds(to: action) == true)
precondition(app.sendAction(action, to: item.target, from: item))
precondition(exits == 1)
print("PASS real menu target/selector/action invokes Harmony exit callback")

}
