import Foundation

func check(_ result: Bool, _ label: String) { precondition(result, label) }

typealias Window = HarmonyPalettePolicy.Window
typealias Kind = HarmonyPalettePolicy.WindowKind
func parents(_ paletteOwners: [Int: Int], _ windows: [Window]) -> [Int: Int] {
    HarmonyPalettePolicy.parentRelationships(paletteOwners: paletteOwners, windows: windows)
}

let initial = [
    Window(id: 11, ownerPID: 100),
    Window(id: 21, ownerPID: 200),
    Window(id: 12, ownerPID: 100)
]
check(parents([71: 100], initial) == [71: 11], "nearest same-owner document")
check(parents([71: 300], initial).isEmpty, "wrong owner")
check(parents([71: 0], initial).isEmpty, "invalid palette owner")
check(parents([71: 100], [Window(id: 11, ownerPID: nil)]).isEmpty, "missing document owner")

let excluded: [Window] = [
    Window(id: 11, ownerPID: 100, kind: .palette),
    Window(id: 12, ownerPID: 100, kind: .sheet),
    Window(id: 13, ownerPID: 100, kind: .dragImage),
    Window(id: 14, ownerPID: 100, kind: .menuBar),
    Window(id: 15, ownerPID: 100, isMinimized: true),
    Window(id: 16, ownerPID: 100, isVanished: true)
]
check(parents([71: 100], excluded).isEmpty, "exclude palette, sheet, drag, menu, minimized and vanished")

let reordered = [
    Window(id: 12, ownerPID: 100),
    Window(id: 11, ownerPID: 100)
]
check(parents([71: 100], reordered) == [71: 12], "reparent to nearest eligible document")
check(parents([11: 100], [Window(id: 11, ownerPID: 100)]) .isEmpty, "never parent to self")
check(parents([71: 100], [Window(id: 71, ownerPID: 100, kind: .document)]) .isEmpty,
      "explicit palette cannot become a document parent")
check(parents([71: 100, 72: 100], [Window(id: 71, ownerPID: 100),
                                    Window(id: 72, ownerPID: 100)]) .isEmpty,
      "palette-only cycle candidates are rejected")

// A pop-up opened from the palette is in front of it and is not its document.
let popup = [
    Window(id: 90, ownerPID: 100),
    Window(id: 71, ownerPID: 100, kind: .palette),
    Window(id: 11, ownerPID: 100)
]
check(parents([71: 100], popup) == [71: 11], "pop-up in front of the palette is not its parent")
check(parents([71: 100], [Window(id: 11, ownerPID: 100), Window(id: 71, ownerPID: 100, kind: .palette)]).isEmpty,
      "no document behind the palette")

print("PASS: owner matching, missing owners, exclusions, reparenting, cycle prevention and pop-ups in front")
