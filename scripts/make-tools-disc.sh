#!/bin/sh
# Make the PowerEmu Tools disc (an HFS+ hybrid ISO the guest mounts like a
# CD) from guest/build.  Usage: scripts/make-tools-disc.sh OUT.iso
set -e
cd "$(dirname "$0")/.."
OUT=${1:?usage: make-tools-disc.sh OUT.iso}
APP="guest/build/Install PowerEmu Tools.app"
[ -d "$APP" ] || { echo "no $APP - run guest/scripts/build.sh first" >&2; exit 1; }
tmp=$(mktemp -d /tmp/pe-tools.XXXXXX); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/PowerEmu Tools"
ditto "$APP" "$tmp/PowerEmu Tools/Install PowerEmu Tools.app"
cat > "$tmp/PowerEmu Tools/Read Me.txt" <<'TXT'
PowerEmu Tools

Open "Install PowerEmu Tools" and click Install. The tools are installed for
your account only (no administrator password) and start when you log in.

They let this virtual Mac:
  - share the clipboard (text) with your Mac,
  - shut down or restart cleanly when you ask PowerEmu to,
  - open folders you share from PowerEmu.

To remove them, open the installer again and click Remove.
TXT
# The disc wears PowerEmu's own icon rather than the system's blank CD.
# A volume icon is a .VolumeIcon.icns at the root; Mac OS X looks for it on
# a disc without needing the custom-icon flag that a hard disk would.
ICON="$tmp/PowerEmu.icns"
if scripts/make-icon.sh "$ICON" >/dev/null 2>&1 && [ -f "$ICON" ]; then
    cp "$ICON" "$tmp/PowerEmu Tools/.VolumeIcon.icns"
else
    echo "warning: no icon built; the disc will look like a blank CD" >&2
fi

rm -f "$OUT"
# makehybrid appends .dmg to the name it is given; the image is raw, and
# laid out for optical media -- 2048-byte sectors, which is what the guest's
# CD drive reads.  An ordinary HFS+ image converted to .cdr is NOT the same
# thing: its 512-byte blocks are unreadable through an ATAPI drive, which is
# what "The disk you inserted was not readable by this computer" means.
hdiutil makehybrid -quiet -hfs -hfs-volume-name "PowerEmu Tools" -o "$tmp/disc" "$tmp/PowerEmu Tools"
mv "$tmp/disc.dmg" "$OUT"
echo "$OUT"
