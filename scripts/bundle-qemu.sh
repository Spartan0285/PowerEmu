#!/bin/bash
# bundle-qemu.sh OUT.app
#
# Package the poweremu-qemu build as a self-contained helper application:
#   OUT.app/Contents/MacOS/qemu-system-ppc
#   OUT.app/Contents/Frameworks/*.dylib      every non-system library, found
#                                            recursively, install names rewritten
#                                            to @executable_path/../Frameworks
#   OUT.app/Contents/Resources/firmware/     OpenBIOS, the NDRV loader and NDRVs
# and sign everything ad hoc.  Nothing outside the bundle is needed at run time
# (no Homebrew), so the app runs on any Apple silicon Mac.
set -euo pipefail

OUT=${1:?usage: bundle-qemu.sh OUT.app}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
QEMU_SRC="${POWEREMU_QEMU:-$HOME/Developer/poweremu-qemu}"
BIN="$QEMU_SRC/build/qemu-system-ppc-unsigned"
ENT="$QEMU_SRC/accel/hvf/entitlements.plist"
[ -x "$BIN" ] || { echo "no QEMU build at $BIN" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Frameworks" "$OUT/Contents/Resources/firmware"
EXE="$OUT/Contents/MacOS/qemu-system-ppc"
cp "$BIN" "$EXE"
chmod u+w "$EXE"
# qemu-img creates blank disks for the app (same libraries).
IMG="$OUT/Contents/MacOS/qemu-img"
if [ -x "$QEMU_SRC/build/qemu-img" ]; then
    cp "$QEMU_SRC/build/qemu-img" "$IMG"
    chmod u+w "$IMG"
fi

is_system() {
    case "$1" in
    /System/*|/usr/lib/*|@executable_path/*|@loader_path/*) return 0 ;;
    *) return 1 ;;
    esac
}

# Resolve an install name (absolute or @rpath) to a file on this machine.
resolve() {
    local name=$1 from=$2
    case "$name" in
    @rpath/*)
        local leaf=${name#@rpath/}
        for dir in $(otool -l "$from" | awk '/LC_RPATH/{getline; getline; print $2}') \
                   /opt/homebrew/lib /usr/local/lib; do
            dir=${dir/@loader_path/$(dirname "$from")}
            [ -e "$dir/$leaf" ] && { echo "$dir/$leaf"; return; }
        done
        echo "" ;;
    *) echo "$name" ;;
    esac
}

queue=("$EXE")
[ -f "$IMG" ] && queue+=("$IMG")
while [ ${#queue[@]} -gt 0 ]; do
    file=${queue[0]}
    queue=("${queue[@]:1}")
    while read -r dep; do
        [ -n "$dep" ] || continue
        is_system "$dep" && continue
        src=$(resolve "$dep" "$file")
        [ -n "$src" ] && [ -e "$src" ] || { echo "cannot find $dep (needed by $file)" >&2; exit 1; }
        leaf=$(basename "$dep")
        dst="$OUT/Contents/Frameworks/$leaf"
        install_name_tool -change "$dep" "@executable_path/../Frameworks/$leaf" "$file" 2>/dev/null
        if [ ! -e "$dst" ]; then            # bash 3.2: no associative arrays
            cp -L "$src" "$dst"
            chmod u+w "$dst"
            install_name_tool -id "@executable_path/../Frameworks/$leaf" "$dst" 2>/dev/null
            queue+=("$dst")
        fi
    done < <(otool -L "$file" | tail -n +2 | awk '{print $1}' | grep -v "^$(otool -D "$file" | tail -1)$" || true)
done

# Firmware: OpenBIOS (patched for the RV280), the NDRV loader, QEMU's VGA NDRV
# and PowerEmu's patched one (hardware cursor, extra modes).
FW="$OUT/Contents/Resources/firmware"
cp "$QEMU_SRC/pc-bios/openbios-ppc" "$QEMU_SRC/pc-bios/ppc-ndrvloader" "$FW/"
[ -f "$QEMU_SRC/pc-bios/qemu_vga.ndrv" ] && cp "$QEMU_SRC/pc-bios/qemu_vga.ndrv" "$FW/"
cp "$HERE/ndrv/qemu_vga_hwc.ndrv" "$FW/"

cat > "$OUT/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>qemu-system-ppc</string>
	<key>CFBundleIdentifier</key>
	<string>com.spartan0285.poweremu.vm</string>
	<key>CFBundleName</key>
	<string>PowerEmu</string>
	<key>CFBundleDisplayName</key>
	<string>PowerEmu</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>The emulated Mac's sound input.</string>
</dict>
</plist>
EOF

# Sign inside out: libraries, then the executable with QEMU's entitlements.
for lib in "$OUT/Contents/Frameworks/"*.dylib; do
    codesign --force --sign - "$lib" >/dev/null 2>&1
done
codesign --force --sign - --entitlements "$ENT" "$EXE" >/dev/null 2>&1
[ -f "$IMG" ] && codesign --force --sign - "$IMG" >/dev/null 2>&1
codesign --force --sign - "$OUT" >/dev/null 2>&1 || true

echo "bundled $(ls "$OUT/Contents/Frameworks" | wc -l | tr -d ' ') libraries into $OUT"
# Every binary must now reference only the system and the bundle.
bad=0
for f in "$EXE" ${IMG:+"$IMG"} "$OUT/Contents/Frameworks/"*.dylib; do
    left=$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -v "^@executable_path/\|^/System/\|^/usr/lib/" || true)
    [ -z "$left" ] || { echo "$(basename "$f") still needs: $left" >&2; bad=1; }
done
[ $bad = 0 ] || exit 1
