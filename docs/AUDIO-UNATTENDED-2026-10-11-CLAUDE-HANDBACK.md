# Audio trace — what changed overnight, 11 October 2026

Written for Codex and for Adam, continuing from
`docs/AUDIO-CLAUDE-HANDOFF-2026-10-10.md`.

**Nothing about playback changed. There is no audio fix and no improved test
build.** This is tooling and diagnosis only. The SM IOProc trace still has not
run, and the reason is now a concrete, nameable blocker that needs one thing
from Adam — see *What I need* at the end.

Evidence: `docs/evidence/audio-unattended-2026-10-11/`. Six owned VM windows,
each registered with the strict 480 s guard, each stopped by QMP `quit` on the
identified VM, each followed by the app being restored and re-signed. The
original Tiger disk was never opened; every run used the existing
`tiger-fresh.qcow2` overlay (backing file `oct08-autonomous-base/tiger.qcow2`,
confirmed by reading the qcow2 header). No commit, push or release was made.

---

## 1. `oct11-sm-ioproc-finalize.py` is fixed, and proven offline

It had failed four times on Adam's machine, each failure costing an owned
window. It now has an offline harness —
`docs/evidence/audio-unattended-2026-10-11/finalize-offline-test.py` — that
stubs only the four boundaries needing a live machine (guest SSH, the read-helper
upload, the collector, QMP) and executes every other line of the real script.

The "fresh capture" fixture is not synthetic. It is the real accepted pair the
2026-10-11 run left behind, `oct10-smtrace-final.{receipt,verification}.json`,
with the real `vmmap_before` of guest pid 259. **32 checks, all passing**: the
happy path and its packed-control invariants, seven refusal paths, and the
evidence-destruction guard.

Two real defects fell out of it.

### 1a. The SndChannel record is not an identity — and pinning it rejected a clean capture

finalize pinned five values against the staged prepare. Four are stable. The
`record` is not. Two captures of the *same process*, three minutes apart:

| | `oct10-smtrace` 00:54 | `oct10-smtrace-final` 00:57 |
|---|---|---|
| record | `0x40c390` | **`0x17a91710`** |
| device | `0x163eea60` | `0x163eea60` |
| hwstate | `0x4464e0` | `0x4464e0` |
| bridge | `0x42c720` | `0x42c720` |
| module_base | `0x162ab000` | `0x162ab000` |
| device_id | 258 | 258 |
| sm_return / core_return | `0x162b07b4` / `0x9146ac0c` | identical |
| accepted | true | true |

Both report `record_list_index 0`, so the device's record list itself is being
reallocated as Warcraft opens and closes sound channels; whichever channel's
IOProc the capture catches on the stack is routinely a different, equally valid
record. My earlier claim that "the SoundManager identities are stable across
boots, record `0x40c390`" was right about four of them and wrong about the record.

Pinning it did two bad things: it refused a capture the collector had already
accepted, and without the pin it would have read the ABL out of
`staged['record']+0xa0` — a channel that had since closed.

finalize now takes the record **fresh** from the capture that proved the chain,
and additionally pins `bridge_target == staged['entry']`. This is stricter, not
looser: the collector has already gated that fresh record as an exact member of
*this* device's record list (begin/end/stride, ≤256 entries) with agreeing
device and HWstate pointers and a qualified DATA mapping. The receipt carries
`record`, `staged_record` and `record_refreshed`, so the substitution is visible
rather than silent. `oct10-validate-sm-ioproc.py` accepts it unchanged — it
requires only that `record` be aligned and ≥ 4096.

> **Worth Codex's attention.** The validator also requires the traced ABL to
> equal the published one (`ablptr==c['abl']`, "published client/ABL identity").
> If the published channel closes inside the 3 s delay + 60 s window, that check
> fails through no fault of the trace. Given how fast the record list churns,
> the observer may need to re-read the record list rather than have one record
> pinned into the control block. That is a plugin change and I have not made it.

### 1b. A VM that failed to pause was left frozen

The pause assertion sat *outside* the `try`/`finally`, so the one refusal that
happens after `stop` would have left Adam's owned emulator stopped until the
480 s guard killed it. The harness caught it as `['stop','query-status']` with no
`cont`. Everything after the stop is now inside the `try`.

### 1c. Three guards that were working against themselves

- `oct11-stage-ownership.py` detected a running emulator by grepping whole
  command lines for `/Contents/MacOS/qemu-system-ppc` — a string present in the
  checker's own command line. Demonstrated on the clean machine: old check
  `True`, new check `False`. It made `restore` refuse and left the QA app staged
  and signed. Both call sites now match the executable field (`ps -ax -o comm=`).
- `stage` now also refuses while the QA app is running: the app reads
  `config.plist` once at launch and keeps it in memory, so staging underneath it
  produced a VM without the staged settings however correct the file looked.
- finalize refuses to clear any label not ending in `-final`. Not hypothetical:
  an earlier harness of mine pointed `FL` at `oct10-sm-scoped-retained` and the
  retry loop deleted three retained evidence files. They were restored from
  `docs/evidence/audio-handoff-2026-10-10/` and are byte-identical to the archive
  (re-verified at the end of tonight's work); the harness now asserts they stay
  byte-identical as its last check.

---

## 2. Driving the trace with nobody at the keyboard

### 2a. Everything up to the game now works unattended

- **Boot.** `autoStart` is true, so `oct11-stage-ownership.py stage` opens the
  app and the VM boots itself. Guest SSH answers **27–54 s** later.
- **Screen readback.** QMP `screendump` works: 1680×1050 PPM, ~5.3 MB. No
  host-side display scope needed.
- **Campaign maps.** They are not on the guest filesystem — they live in the
  archive — but the host already has both the archive (`oct10-war3-source.mpq`)
  and a read-only StormLib reader (`oct10-mpq-read`) from the 2026-10-10 work.
  `Maps\Campaign\Prologue01.w3m` extracts cleanly (299,288 bytes, `HM3W`) and is
  now installed in the guest's own `Maps/` folder with a matching MD5.

### 2b. Real input injection — this removes the "synthetic clicks" blocker

"Warcraft ignores synthetic background clicks" was true of every host-side route
we had tried, and it is *also* true of the guest's own accessibility API:
System Events reports `click button "Cancel"` as succeeding while the Carbon
dialog sits there unmoved — four times in a row.

QEMU's `input-send-event` is a different thing. It posts to the guest's USB
tablet (the VM has one: `-device usb-tablet`), so the guest cannot distinguish
it from Adam's own mouse. **The same button that ignored four accessibility
clicks was dismissed by the first injected one.** Coordinates come from the
accessibility API where it can see the control — it gave
`Cancel at (936,563) 72x20`, so the click went to (972,573) with nothing read
from pixels.

Helper: `/tmp/pe9800/oct11-guest-input.py <qmp-socket> click X Y | move X Y | key <qcode>…`.

This is the general answer to GUI navigation in this guest, not just to this
dialog.

### 2c. Two corrections to things I had previously inferred

- **There was never a command-line map load.** The
  `... /Warcraft III /Applications/Warcraft III Folde…` argv in the 2026-10-10
  "map-loaded" capture is LaunchServices repeating the app path, not a map
  argument. And there could not have been one: the binary is `-rw-r--r--`, an
  11 MB 2002 CFM/Carbon app whose code is in the resource fork. `exec` returns
  `Permission denied`, and there is no Mach-O header to run. `open <map.w3m>`
  launches the game (the type is bound `'Ww3m'`) but delivers the map as an
  `'odoc'` Apple Event.
- **`experimentalGraphicsCard` is a string enum** (`"9200"`/`"9800"`). Writing
  the integer `9200` makes the whole config fail to decode, so the app opens and
  silently never starts a VM. That cost one window.

### 2d. CORRECTED — the CD is not a blocker; I was launching the wrong binary

**Everything in this subsection was wrong, and the corrected account is in
`docs/SM-IOPROC-TRACE-2026-10-11.md`.** Adam pointed out that the guest has
`/Users/adam/Desktop/Warcraft III ROC [NoCD].app` — an applet bundle that is
how every earlier session launched the game. I had been launching
`/Applications/Warcraft III Folder/Warcraft III` directly, which is the only
thing that sits on the CD prompt. Through the NoCD applet the game comes up in
~7 s and renders the main menu at ~108 % CPU on the unmodified config, and the
trace has since run to completion against the Prologue cinematic.

The measurements below are still accurate as measurements — the CD dialog is
real, Cancel does quit the game, and the dialog does ignore accessibility
clicks while obeying injected ones. The *conclusion* drawn from them, that no
unattended run was possible without a disc, was wrong. Retained unedited:

### 2d (superseded). The game wants the CD, and will not be talked out of it

Launched **plainly**, with no document at all, Warcraft III puts up
*"Please insert the Warcraft III CD."* and waits — 250 s observed, 0.1–3.4 % CPU,
never proceeding (`oct11-plain.t250.png`). Same for a melee map and for a
campaign map. Clicking Cancel with a real injected click — the one it does obey
— makes the game **quit**.

No disc is configured in either VM bundle (`discs: []`), and none is mounted.
This is a genuine disc check and I am not going to defeat it.

On the 9800 the game does not even reach its CD check within 78 s and shows no
window at all; on the 9200 the dialog is up in ~25 s. That is consistent with
"Warcraft 3 hangs on launch" on the 9800 and is a separate problem from the audio.

---

## What I needed from Adam — RESOLVED

**This asked for the Warcraft III CD. That was not what was needed.** The
answer was the NoCD applet already sitting on the guest Desktop. Superseded
text follows.

**One thing: the Warcraft III CD, available to the guest.** Either

- a disc image on the host, added to the test VM's `discs` in
  `oct08-autonomous-support/Virtual Machines/Tiger Audio Test.poweremu/config.plist`
  (tell me the path and I will wire it up read-only), or
- the disc's contents in the PowerEmu Drop share — which is how I now think the
  2026-10-10 session satisfied the check, since `mount_webdav … -vPowerEmu Drop`
  was running in that capture and the IORegistry from it shows no CD media at
  all, only `disk0` and `disk1`.

With that in place the whole sequence is unattended: stage → boot → `open` the
map → inject clicks through the menus with coordinates read back by
`screendump` → prepare → publish → trace → validate. Every piece of that except
the disc is built and exercised.

One honesty note for whoever runs it: the READY receipt that `finalize` requires
(`cue == 'READY'`, `ready_verified is True`) currently means *a human confirmed
the guest is in the traced state*. If that confirmation becomes automatic —
screendump plus process state — the receipt should record **how** it was
established rather than quietly reusing the human-confirmed field. I have not
changed that assertion.

## Still open from before tonight

- Chess's black background; `POWEREMU_R350_RESOLVE_TEX` is still unexercised.
- `direct-vram` was identified as the Warcraft framerate lead and has never been
  measured.
- The observer may need to re-read the record list rather than carry one pinned
  record (§1a).
