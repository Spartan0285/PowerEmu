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
rm -f "$OUT"
# makehybrid appends .dmg to the name it is given; the image is raw.
hdiutil makehybrid -quiet -hfs -hfs-volume-name "PowerEmu Tools" -o "$tmp/disc" "$tmp/PowerEmu Tools"
mv "$tmp/disc.dmg" "$OUT"
echo "$OUT"
