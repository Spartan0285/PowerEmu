import Foundation

/// Saved machines must wake with the graphics devices in their snapshot.
/// Only a fresh boot may remove the second guest graphics card.
enum DisplayStartup {
    enum Action: Equatable {
        case unchanged
        case useOneScreen
        case resumeBothScreens
    }

    static func action(configuredScreens: Int, hostScreens: Int,
                       classic: Bool, savedState: Bool) -> Action {
        guard !classic, configuredScreens > 1, hostScreens < 2 else {
            return .unchanged
        }
        return savedState ? .resumeBothScreens : .useOneScreen
    }
}
