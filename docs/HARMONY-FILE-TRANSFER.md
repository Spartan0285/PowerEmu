# Harmony file transfer — Tools 2.16

This is the alpha implementation and tester contract for dragging files between the host and a Tiger guest.

## Supported gestures

| Gesture | Result |
|---|---|
| Host Finder/Desktop → guest Finder window | Copies into the folder shown by that window |
| Host Finder/Desktop → guest application window | Copies into `~/Documents/PowerEmu Imports/<transfer>` and opens in that application |
| Host Finder/Desktop → guest application's host Dock icon | Copies and opens in that guest application |
| Host application file promise → guest window | Receives the promise, then copies/opens it as above |
| Guest Finder item → host Finder/Desktop | Produces a native host file promise at the drop destination |
| Guest Finder item → host application | Produces a native promise when that application accepts file drops |

The host-to-guest cursor must be over the guest window or Dock tile when released. A guest-to-host drag remains a guest drag while it crosses other guest windows; PowerEmu hands it to AppKit after it leaves the guest-window group. Only the Finder item actually under the initial press can arm an export.

## Data path and safety

The control connection sends only property-list metadata and completion/error messages. File bytes use a private, randomly named per-VM staging directory exposed through PowerEmu's guest-only WebDAV bridge. This prevents a large copy from delaying menus, focus, input, or window surfaces.

`ditto` ZIP archives preserve Tiger resource forks and directory metadata. Both endpoints validate filenames and archive structure before extraction. The host validator checks central and local headers, path components, entry types, size bounds, and header agreement. The Tiger validator runs before `ditto` sees inbound data. Neither side overwrites an existing file.

Transfers are copy operations. Dropping never deletes the source. App-targeted guest files remain in Documents because the guest application may continue editing them after the drag completes.

## Alpha limits

- At most 256 files or folders per drag.
- At most 4 GB uncompressed per item; ZIP64 and encrypted ZIPs are rejected.
- Symbolic links and special filesystem nodes are rejected. A user can explicitly archive such a folder and drag the archive.
- Guest-to-host source drags begin in Finder. Dragging internal document objects from other guest applications is outside this alpha.
- A Finder window must resolve to one writable folder. Search/result views without a single folder destination fail with an explanation.

## Tester pass

1. Install PowerEmu Tools 2.16 from the Tools disc and enter Harmony.
2. Drag a small text file and a folder from host Finder into a guest Finder folder. Confirm they appear in that exact folder.
3. Repeat one drop. Confirm the existing file remains and the new one uses ` (2)`.
4. Drag a file onto a guest TextEdit window and onto its host Dock icon. Confirm TextEdit opens both copies.
5. Drag a guest Finder file to the host Desktop and into a host Finder folder.
6. Drag two selected guest Finder items to the host. Confirm both arrive and the surface remains responsive during transfer.
7. Start a larger copy, then quit or disconnect the guest. Confirm the host reports failure rather than leaving a drag indefinitely active.

Record the exact source, target, and error text for failures. Do not retry a timed-out host-to-guest copy until checking the destination; the guest may have completed it just before the connection failed.
