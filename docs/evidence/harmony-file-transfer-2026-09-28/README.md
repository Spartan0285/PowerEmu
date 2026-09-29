# Harmony file-transfer evidence

Candidate: `build/Harmony File Transfer/PowerEmu.app`  
Guest tools: 2.14  
Date: September 28, 2026

The signed candidate contains the Tools ISO with native Install and Uninstall packages. Deep/strict code-signing verification passed with Adam Cipoletti's Developer ID identity. Tiger's `installer -pkginfo` recognized both freshly built packages.

`integration.log` is the isolated Tiger 10.4.11 run against the production guest agent and production WebDAV server. It verifies exact Finder-window targeting, collision naming, resource-fork preservation, outbound Finder export, invalid-target rejection, archive traversal rejection, and Open Documents delivery to TextEdit.

`host-regressions.log` covers archive validation, Unicode/newline names, directory and single-file resource forks, collision refusal, symlink refusal, guest-return extraction, control-channel trust, native file-promise writes, serialization, and disconnect completion. `dock-open.log` verifies that a generated guest Dock tile accepts a host document and reports the scoped VM session, guest PID, and exact path.

The interactive tester checklist and declared alpha limits are in `docs/HARMONY-FILE-TRANSFER.md`.
