#!/bin/bash
# build-app.sh : build PowerEmu.app into build/
#   PowerEmu.app/Contents/MacOS/PowerEmu               the SwiftUI app
#   PowerEmu.app/Contents/Helpers/PowerEmu VM.app      QEMU + libraries + firmware
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/PowerEmu.app"
VERSION=0.1
# The build number is what an updater compares and what a feedback report
# carries, so it is a whole number and it goes up on every release.
BUILD_NUMBER=1
# The stage, in one place: it shows in the About badge and travels with every
# feedback report. Empty it when this is no longer an alpha and it disappears
# from both. Never put it in VERSION -- that string ends up in file names and
# tags, and a space in it finds every one of them.
STAGE=Alpha

(cd "$ROOT/app" && swift build -c release)
BIN="$(cd "$ROOT/app" && swift build -c release --show-bin-path)/PowerEmu"

# Restage the helper (QEMU + its libraries) whenever the emulator has been
# rebuilt since; otherwise the app would keep shipping the QEMU it was first
# packaged with, and changes to the emulator would silently never appear.
QEMU_BIN="${POWEREMU_QEMU:-$HOME/Developer/poweremu-qemu}/build/qemu-system-ppc-unsigned"
STAGED="$ROOT/build/PowerEmu VM.app/Contents/MacOS/qemu-system-ppc"
if [ ! -d "$ROOT/build/PowerEmu VM.app" ] || [ "$QEMU_BIN" -nt "$STAGED" ]; then
    "$ROOT/scripts/bundle-qemu.sh" "$ROOT/build/PowerEmu VM.app"
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Helpers" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/PowerEmu"
ditto "$ROOT/build/PowerEmu VM.app" "$OUT/Contents/Helpers/PowerEmu VM.app"
cp "$ROOT/LICENSE" "$ROOT/COPYING" "$ROOT/THIRD-PARTY-NOTICES.md" "$OUT/Contents/Resources/"
cp "$ROOT/app/Resources/cytruslogo.png" "$ROOT/app/Resources/cytruslogo-dark.png" "$OUT/Contents/Resources/"
# Machine icons macOS no longer has (the Cube); the rest come from the system.
cp "$ROOT"/app/Resources/Models/*.png "$OUT/Contents/Resources/" 2>/dev/null || true
# Files dragged in from elsewhere carry Finder metadata, and codesign
# refuses a bundle containing it ("resource fork ... not allowed").
xattr -cr "$OUT/Contents/Resources" 2>/dev/null || true
# The app icon, flattened from assets/poweremu.icon.
ICON_CAR_DIR="$OUT/Contents/Resources" \
    "$ROOT/scripts/make-icon.sh" "$OUT/Contents/Resources/PowerEmu.icns" >/dev/null
# The PowerEmu Tools disc (guest/scripts/build.sh builds its apps on a PowerPC Mac).
if [ -d "$ROOT/guest/build/Install PowerEmu Tools.app" ]; then
    "$ROOT/scripts/make-tools-disc.sh" "$OUT/Contents/Resources/PowerEmu Tools.iso" >/dev/null
else
    echo "warning: guest/build is empty; PowerEmu.app will have no Tools disc" >&2
fi

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>PowerEmu</string>
	<key>CFBundleIconFile</key>
	<string>PowerEmu</string>
	<!-- Names the icon inside Assets.car. Without this macOS 26 falls back to
	     CFBundleIconFile and draws the .icns inset in its own container,
	     which makes a full-bleed icon look small. -->
	<key>CFBundleIconName</key>
	<string>poweremu</string>
	<key>CFBundleIdentifier</key>
	<string>com.spartan0285.poweremu</string>
	<key>CFBundleName</key>
	<string>PowerEmu</string>
	<key>CFBundleDisplayName</key>
	<string>PowerEmu</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>PEBuildStage</key>
	<string>$STAGE</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>PowerEmu is free software under the GNU GPL v2 or later.</string>
</dict>
</plist>
EOF

# Signing.  Ad hoc by default; with a real identity every build has the same
# designated requirement, so the Keychain keeps trusting PowerEmu with its
# saved passwords across updates (ad-hoc builds each look like a new app).
# Set POWEREMU_SIGN_IDENTITY, or put the identity's name in
# scripts/signing.local (not in git), e.g.
#   Developer ID Application: Your Name (TEAMID)
SIGN=${POWEREMU_SIGN_IDENTITY:-}
[ -z "$SIGN" ] && [ -f "$ROOT/scripts/signing.local" ] && SIGN=$(head -1 "$ROOT/scripts/signing.local")
SIGN=${SIGN:--}
HELPER="$OUT/Contents/Helpers/PowerEmu VM.app"
if [ "$SIGN" != "-" ]; then
    for f in "$HELPER"/Contents/Frameworks/*.dylib "$HELPER/Contents/MacOS/qemu-img"; do
        [ -f "$f" ] && codesign --force --sign "$SIGN" --timestamp=none "$f" >/dev/null
    done
    codesign --force --sign "$SIGN" --timestamp=none --entitlements "${POWEREMU_QEMU:-$HOME/Developer/poweremu-qemu}/accel/hvf/entitlements.plist" \
        "$HELPER/Contents/MacOS/qemu-system-ppc" >/dev/null
    codesign --force --sign "$SIGN" --timestamp=none "$HELPER" >/dev/null
fi
codesign --force --sign "$SIGN" --timestamp=none "$OUT/Contents/MacOS/PowerEmu" >/dev/null
codesign --force --sign "$SIGN" --timestamp=none "$OUT" >/dev/null
echo "signed: $SIGN"
echo "built $OUT ($(du -sh "$OUT" | cut -f1))"
