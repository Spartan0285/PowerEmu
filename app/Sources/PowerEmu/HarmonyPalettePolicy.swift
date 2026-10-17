import Foundation

/// Selects a document proxy to own each explicitly classified palette proxy.
///
/// `windows` must be in guest front-to-back order. Palette classification is
/// supplied separately by the caller; this policy does not infer it from a
/// window's level, title, or geometry.
enum HarmonyPalettePolicy {
    enum WindowKind {
        case document
        case palette
        case sheet
        case dragImage
        case menuBar
        case other
    }

    struct Window {
        let id: Int
        let ownerPID: Int?
        let kind: WindowKind
        let isMinimized: Bool
        let isVanished: Bool

        init(id: Int, ownerPID: Int?, kind: WindowKind = .document,
             isMinimized: Bool = false, isVanished: Bool = false) {
            self.id = id
            self.ownerPID = ownerPID
            self.kind = kind
            self.isMinimized = isMinimized
            self.isVanished = isVanished
        }
    }

    /// Returns `paletteID -> documentID`. The first eligible document behind
    /// the palette in front-to-back order wins, so a palette follows its
    /// nearest visible same-process document when that ordering changes.
    /// Only windows behind it count: a palette floats over its documents, and
    /// what is in front of it (a pop-up list opened from it) is not one.
    static func parentRelationships(paletteOwners: [Int: Int],
                                    windows: [Window]) -> [Int: Int] {
        let paletteIDs = Set(paletteOwners.keys)
        let candidates = windows.filter { window in
            guard window.id > 0, !paletteIDs.contains(window.id),
                  window.kind == .document,
                  !window.isMinimized, !window.isVanished,
                  let ownerPID = window.ownerPID, ownerPID > 0 else { return false }
            return true
        }

        var relationships: [Int: Int] = [:]
        for paletteID in paletteOwners.keys.sorted() {
            let behind = windows.firstIndex(where: { $0.id == paletteID })
                .map { Set(windows[($0 + 1)...].map(\.id)) }
            guard paletteID > 0, let ownerPID = paletteOwners[paletteID], ownerPID > 0,
                  let parent = candidates.first(where: {
                      $0.ownerPID == ownerPID && behind?.contains($0.id) != false
                  }),
                  parent.id != paletteID else { continue }
            relationships[paletteID] = parent.id
        }
        return relationships
    }
}

extension HarmonyPalettePolicy.WindowKind: Equatable {}
