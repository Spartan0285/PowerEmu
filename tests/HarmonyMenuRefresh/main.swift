import AppKit

func harmonyDebug(_ text: String) {}

private func require(_ condition: Bool, _ message: String) {
    guard condition else {
        fputs("FAIL: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private func pause(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.mainMenu = NSMenu(title: "Fixture")
    let bar = HarmonyMenuBar()
    var requests: [String] = []
    bar.send = { verb, payload in requests.append("\(verb):\(payload)") }
    bar.setGuestWindowFocused(true)
    bar.setMenuBar(pid: 42, app: "Word", tops: [(index: 1, title: "Font")])
    pause(0.2) // allow the normal one-time prefetch to run
    require(requests == ["MENUITEMS:42 1"], "initial menu prefetch is sent once")

    guard let fontMenu = app.mainMenu?.item(at: 1)?.submenu else {
        require(false, "font menu installed")
        return
    }
    // The guest can intentionally drop a stale AX read. Retry only on a real
    // menu open after the in-flight request has exceeded its timeout.
    pause(2.05)
    bar.menuWillOpen(fontMenu)
    require(requests.count == 2 && requests.last == "MENUITEMS:42 1",
            "opening a menu retries a request that timed out")
    bar.menuWillOpen(fontMenu)
    require(requests.count == 2, "repeated opens do not duplicate an in-flight request")

    bar.setItems(pid: 42, path: "1", items: [])
    require(bar.dump("1").hasPrefix("Loading…"), "empty response replaces stale actions with a retryable placeholder")
    pause(0.8)
    bar.menuWillOpen(fontMenu)
    require(requests.count == 3, "opening an empty menu retries its contents")
    bar.menuWillOpen(fontMenu)
    require(requests.count == 3, "repeated opens do not duplicate an in-flight request")

    let initial = HarmonyMenuItem(path: "1.0", title: "Arial", enabled: true,
                                  key: "", modifiers: 0, mark: "", hasSubmenu: false)
    bar.setItems(pid: 42, path: "1", items: [initial])
    require(bar.dump("1") == "Arial", "nonempty response fills the menu")

    pause(0.8)
    bar.menuWillOpen(fontMenu)
    require(requests.count == 4, "later real opens refresh cached dynamic contents")
    bar.menuWillOpen(fontMenu)
    require(requests.count == 4, "refresh cooldown bounds repeated open requests")

    let refreshed = HarmonyMenuItem(path: "1.0", title: "Arial Black", enabled: true,
                                    key: "", modifiers: 0, mark: "", hasSubmenu: false)
    bar.setItems(pid: 42, path: "1", items: [refreshed])
    require(bar.dump("1") == "Arial Black", "fresh response replaces stale menu contents")
    bar.setItems(pid: 42, path: "1", items: [])
    require(bar.dump("1").hasPrefix("Loading…"), "empty refresh removes stale actionable contents")
    pause(0.8)
    bar.menuWillOpen(fontMenu)
    require(requests.count == 5, "empty refresh remains retryable on a later open")

    bar.remove()
    requests.removeAll()
    bar.setGuestWindowFocused(true)
    bar.setMenuBar(pid: 42, app: "Word", tops: [(index: 1, title: "Old") , (index: 3, title: "Old delayed")])
    bar.remove()
    bar.setGuestWindowFocused(true)
    bar.setMenuBar(pid: 42, app: "Word", tops: [(index: 2, title: "Edit")])
    pause(0.35)
    require(requests == ["MENUITEMS:42 2"], "delayed prefetch from removed same-PID menu generation is ignored")
    bar.remove()
    print("PASS: Harmony menu dropped-request retry, empty-result placeholder, in-flight deduplication, bounded refresh, and stale prefetch generation guard")
}
