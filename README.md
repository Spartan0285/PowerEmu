# PowerEmu

Run Mac OS X 10.4 Tiger and 10.5 Leopard for PowerPC - with Quartz Extreme,
3D games and Classic - on Apple silicon Macs. Built on
[poweremu-qemu](https://github.com/Spartan0285/poweremu-qemu) (QEMU `mac99`
with an emulated ATI Radeon 9000 rendered through Metal).

## What is here today

| Folder | Contents |
|---|---|
| `launcher/` | `launch-tiger-ati.sh` - starts a Tiger guest (GPU, AGP, audio, USB, networking, hardware cursor, host-aspect display modes, fullscreen); `launch-tiger-install.sh` for installs |
| `ndrv/` | `build.py` patches QEMU's VGA NDRV (`qemu_vga.orig.ndrv`) into `qemu_vga_hwc.ndrv`: hardware cursor + extra display modes |
| `tools/` | Guest control and test harness: boot/shutdown (`vmboot.sh`, `vmdown.sh`), monitor (`hmp.sh`), ssh (`gssh.sh`), mouse (`rmouse.py`), screenshots (`shot.sh`), cursor/audio checks, `listmodes`/`setmode` (guest display modes), `paste-to-guest.py` |
| `docs/` | Change history |

### Running

The launcher expects a built `poweremu-qemu` checkout
(`$POWEREMU_QEMU`, default `~/Developer/poweremu-qemu`) and a VM folder
(`$POWEREMU_VM_DIR`) holding the guest disk (`tiger-fresh.qcow2`), `kexts.img`
and the ATI ROM images `ati_ndrv_joy.rom` / `ati_ret_9200_201_pciagp_full.rom`.
Guest disks, install media and ROM images are not part of this repository.

Switches: `FULLSCREEN=on`, `HWCURSOR=off`, `AUDIO=none|coreaudio|driver=wav,...`,
`MEM=2048`, `TABLET=on`, `VERBOSE=on`, `TRACE_GPU=on`, `AGPBRIDGE=on`.

The tools reach the guest over ssh on localhost:2222 with the key in
`$POWEREMU_GUEST_KEY` (default `~/.ssh/poweremu_guest`), and the QEMU monitor
on localhost:4444.

## Plan: PowerEmu.app

A native macOS app around the emulator:

1. **Foundation** - self-contained QEMU (bundled dylibs, signed with the JIT
   entitlement), VM documents (`.poweremu`: disks + settings).
2. **App** - VM library, create-from-install-disc, settings, start/stop via
   QMP, display resolutions (custom modes through the NDRV mode table), boot
   options (verbose `-v`, safe boot `-x`, single user, reset PRAM), boot chime,
   fullscreen (whole panel or below the notch).
3. **Storage** - create/import/attach disks, startup disk, disc images, the
   Mac's CD/DVD drive and USB floppies attached as guest drives (hot-plug).
4. **Guest Tools** (Tiger/Leopard, PPC) - clipboard sync, shared folders via a
   WebDAV server in PowerEmu (Tiger's Finder mounts WebDAV natively), clean
   shutdown, time sync, later dynamic resolution.
