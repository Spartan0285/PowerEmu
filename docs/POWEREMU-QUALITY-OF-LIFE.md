# Configuration and VM library improvements

The Dock menu now offers **Show Configuration**. The configuration scene is a
single window: the action activates PowerEmu, opens it if closed, and brings
it forward if minimized. Harmony does not need to be exited.

The sidebar supports SwiftUI list reordering and row context-menu **Move Up** /
**Move Down** commands. Order is saved atomically in `vm-order.json` alongside
the VM library, keyed by package filename. Previously unseen VMs follow saved
entries in name order. Reloads retain existing VM objects so live machines
keep their connections and state. Reordering leaves the selected VM intact.

Settings are divided into General, Storage, Display, Sharing, Devices, and
Advanced tabs. The VM summary and start/status controls remain above the tabs.
Each tab scrolls independently. Existing running-machine restrictions remain,
and the duplicate Single-user mode control has been removed.

## Verification

- Release build and strict/deep code-signature verification passed.
- Used a separate preview app and three diskless, non-autostart VM fixtures.
- Visually checked the tab layout; inspected General, Storage, and Devices.
- Context-menu reorder changed Leopard/Panther/Tiger to Leopard/Tiger/Panther.
- Saved order was present after reopening the preview; selection stayed intact
  during the move.
- UI tooling could not access the Dock menu, and coordinate dragging could not
  be verified with it. Manual checks remain for dragging rows and the Dock
  shortcut with the configuration window closed or minimized.

Build: `build/PowerEmu Quality of Life/PowerEmu.app`. Includes the earlier
Harmony fixes and bundled Tools 2.18. No guest-tools update is required solely
for these configuration changes.
