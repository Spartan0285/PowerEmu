#!/bin/sh
# Make the PowerEmu Tools disc (an HFS+ hybrid ISO the guest mounts like a
# CD) from guest/build.  Usage: scripts/make-tools-disc.sh OUT.iso
set -e
cd "$(dirname "$0")/.."
OUT=${1:?usage: make-tools-disc.sh OUT.iso}
INSTALL="guest/build/Install PowerEmu Tools.pkg"
UNINSTALL="guest/build/Uninstall PowerEmu Tools.pkg"
[ -d "$INSTALL" ] && [ -d "$UNINSTALL" ] || { echo "Build guest packages first" >&2; exit 1; }
tmp=$(mktemp -d /tmp/pe-tools.XXXXXX); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/PowerEmu Tools"
ditto "$INSTALL" "$tmp/PowerEmu Tools/Install PowerEmu Tools.pkg"
ditto "$UNINSTALL" "$tmp/PowerEmu Tools/Uninstall PowerEmu Tools.pkg"
cat > "$tmp/PowerEmu Tools/Read Me.txt" <<'TXT'
PowerEmu Tools

Open Install PowerEmu Tools.pkg and follow the Mac OS X Installer steps.
An administrator password enables guest window control. Tools are installed
for the logged-in guest account and start automatically at login.
Installing again updates or repairs Tools; it cannot uninstall them.

To remove Tools, open the separate Uninstall PowerEmu Tools.pkg.
Removal disables Harmony, shared clipboard and guest integration for this
account and removes the optional clock service.

In Harmony, drag files and folders between the host and guest Finder. Files
can also be dropped on guest application windows and their host Dock icons.
PowerEmu preserves classic Mac resource forks and Finder metadata.

TXT
# The disc wears PowerEmu's own icon rather than the system's blank CD.
# A volume icon is a .VolumeIcon.icns at the root; Mac OS X looks for it on
# a disc without needing the custom-icon flag that a hard disk would.
# Classic icon elements generated on the PowerBook work in Tiger's Finder.
cp guest/Resources/PowerEmu.icns "$tmp/PowerEmu Tools/.VolumeIcon.icns"

rm -f "$OUT"
# makehybrid appends .dmg to the name it is given; the image is raw, and
# laid out for optical media -- 2048-byte sectors, which is what the guest's
# CD drive reads.  An ordinary HFS+ image converted to .cdr is NOT the same
# thing: its 512-byte blocks are unreadable through an ATAPI drive, which is
# what "The disk you inserted was not readable by this computer" means.
hdiutil makehybrid -quiet -hfs -hfs-volume-name "PowerEmu Tools" -o "$tmp/disc" "$tmp/PowerEmu Tools"
mv "$tmp/disc.dmg" "$OUT"
echo "$OUT"
