import Foundation

/// A hover is not a drop. Only the same drag in the same Harmony session
/// may commit, after the destination has been checked again at release.
struct HarmonyDropIntent {
    private var entered: (sequence: Int, epoch: UUID)?
    mutating func enter(sequence: Int, epoch: UUID) { entered = (sequence, epoch) }
    mutating func cancel() { entered = nil }
    func accepts(sequence: Int, epoch: UUID, destinationValid: Bool) -> Bool {
        destinationValid && entered?.sequence == sequence && entered?.epoch == epoch
    }
    mutating func consume(sequence: Int, epoch: UUID, destinationValid: Bool) -> Bool {
        let result = accepts(sequence: sequence, epoch: epoch, destinationValid: destinationValid)
        cancel()
        return result
    }
}

#if canImport(AppKit)
import AppKit

/// Shared by the real proxy and the native drag integration fixture.
/// Test the destination before raising it; a hover never grants ownership
/// of a later drop on another window or on the desktop.
@MainActor
func harmonyDropHitsView(_ info: NSDraggingInfo, view: NSView, window: NSWindow) -> Bool {
    guard view.window === window, info.draggingDestinationWindow === window,
          window.isVisible, !window.isMiniaturized, !view.isHiddenOrHasHiddenAncestor,
          info.draggingSourceOperationMask.contains(.copy) else { return false }
    let local = view.convert(info.draggingLocation, from: nil)
    let screen = window.convertPoint(toScreen: info.draggingLocation)
    return view.visibleRect.contains(local)
        && NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) == window.windowNumber
}
#endif
