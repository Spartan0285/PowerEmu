# Third-party components

PowerEmu's own code is GPL-2.0-or-later (see `LICENSE` and `COPYING`).

| Component | Where | License | Source |
|---|---|---|---|
| QEMU VGA NDRV (`qemu_vga.ndrv`) | `ndrv/qemu_vga.orig.ndrv`, unmodified | GPL-2.0 | [QemuMacDrivers](https://github.com/ozbenh/QemuMacDrivers) |
| Patched NDRV (hardware cursor, extra modes) | `ndrv/qemu_vga_hwc.ndrv`, generated from the above by `ndrv/build.py` | GPL-2.0 | this repository (`ndrv/build.py`) + QemuMacDrivers |
| QEMU, OpenBIOS | used by `launcher/` from the separate `poweremu-qemu` build | GPL-2.0 | [poweremu-qemu](https://github.com/Spartan0285/poweremu-qemu) |
| `ppc-ndrvloader` | in `poweremu-qemu/pc-bios` | MIT | [classicvirtio](https://github.com/elliotnunn/classicvirtio) |

Not part of this repository and not redistributable: Mac OS X / Mac OS 9 and
any Apple software, ATI option ROMs and drivers, and guest disk images.
Users supply their own install media.
