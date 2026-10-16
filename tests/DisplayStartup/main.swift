import Foundation

func action(_ configured: Int, _ host: Int, sleep: Bool = false,
            classic: Bool = false) -> DisplayStartup.Action {
    DisplayStartup.action(configuredScreens: configured, hostScreens: host,
                          classic: classic, savedState: sleep)
}

precondition(action(2, 1) == .useOneScreen)
precondition(action(2, 0) == .useOneScreen)
precondition(action(2, 2) == .unchanged)
precondition(action(2, 3) == .unchanged)
precondition(action(1, 1) == .unchanged)
precondition(action(1, 2) == .unchanged)
precondition(action(2, 1, classic: true) == .unchanged)
// A saved-state restore must never remove a graphics device behind the
// guest's back, even when only one physical monitor remains connected.
precondition(action(2, 1, sleep: true) == .resumeBothScreens)
precondition(action(2, 0, sleep: true) == .resumeBothScreens)
precondition(action(2, 2, sleep: true) == .unchanged)
precondition(action(1, 1, sleep: true) == .unchanged)
print("Display startup: missing displays, normal boots and saved-state preservation passed")
