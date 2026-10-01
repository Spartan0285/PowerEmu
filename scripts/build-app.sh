#!/bin/bash
# build-app.sh : build PowerEmu.app into build/
#   PowerEmu.app/Contents/MacOS/PowerEmu               the SwiftUI app
#   PowerEmu.app/Contents/Helpers/PowerEmu VM.app      QEMU + libraries + firmware
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${POWEREMU_APP_OUT:-$ROOT/build/PowerEmu.app}"
HELPER_STAGE="${POWEREMU_HELPER_STAGE:-$ROOT/build/PowerEmu VM.app}"
# A release sets these (see scripts/release.sh); a development build keeps
# the defaults so it always looks older than anything published.
VERSION="${POWEREMU_VERSION:-0.1}"
# The build number is what an updater compares and what a feedback report
# carries, so it is a whole number and it goes up on every release.
BUILD_NUMBER="${POWEREMU_BUILD:-1}"
# The stage, in one place: it shows in the About badge and travels with every
# feedback report. Empty it when this is no longer an alpha and it disappears
# from both. Never put it in VERSION -- that string ends up in file names and
# tags, and a space in it finds every one of them.
STAGE=Alpha
BUNDLE_ID="${POWEREMU_BUNDLE_ID:-com.spartan0285.poweremu}"
DISPLAY_NAME="${POWEREMU_DISPLAY_NAME:-PowerEmu}"
R350_EXPERIMENT="${POWEREMU_R350_EXPERIMENT:-0}"

# The Tools disc and the app must agree on the version, or PowerEmu would
# offer an update to the copy it is already running (or miss a real one).
agent_v=$(sed -n 's/^#define PE_AGENT_VERSION "\(.*\)"/\1/p' "$ROOT/guest/src/PEAgent.m")
app_v=$(sed -n 's/.*static let shippedVersion = "\(.*\)"/\1/p' "$ROOT/app/Sources/PowerEmu/GuestTools.swift")
if [ -n "$agent_v" ] && [ "$agent_v" != "$app_v" ]; then
    echo "error: PE_AGENT_VERSION ($agent_v) != GuestTools.shippedVersion ($app_v)" >&2
    exit 1
fi

(cd "$ROOT/app" && swift build -c release)
BIN="$(cd "$ROOT/app" && swift build -c release --show-bin-path)/PowerEmu"

# Restage the helper (QEMU + its libraries) whenever the emulator has been
# rebuilt since; otherwise the app would keep shipping the QEMU it was first
# packaged with, and changes to the emulator would silently never appear.
QEMU_BIN="${POWEREMU_QEMU_BINARY:-${POWEREMU_QEMU:-$HOME/Developer/poweremu-qemu}/build/qemu-system-ppc-unsigned}"
STAGED="$HELPER_STAGE/Contents/MacOS/qemu-system-ppc"
if [ ! -d "$HELPER_STAGE" ] || [ "$QEMU_BIN" -nt "$STAGED" ] || [ -n "${POWEREMU_QEMU_BINARY:-}${POWEREMU_OPENBIOS:-}" ]; then
    "$ROOT/scripts/bundle-qemu.sh" "$HELPER_STAGE"
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Helpers" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/PowerEmu"
ditto "$HELPER_STAGE" "$OUT/Contents/Helpers/PowerEmu VM.app"
# The network helper: the only piece that ever runs as an administrator,
# and it does nothing but carry ethernet frames for a bridged virtual Mac.
# One guest application's place in this Mac's Dock: PowerEmu copies this into
# a small bundle of its own for each application the guest is running.
xcrun swiftc -O -target arm64-apple-macos12.0 \
    "$ROOT/helper/main.swift" -o "$OUT/Contents/Helpers/PowerEmuGuestApp"

cc -O2 -Wall -o "$OUT/Contents/Helpers/poweremu-netd" "$ROOT/helper/poweremu-netd.c" \
   -framework vmnet -framework Foundation
cp "$ROOT/LICENSE" "$ROOT/COPYING" "$ROOT/THIRD-PARTY-NOTICES.md" "$ROOT/TERMS.md" "$OUT/Contents/Resources/"
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
if [ -d "$ROOT/guest/build/Install PowerEmu Tools.pkg" ]; then
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
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$DISPLAY_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$DISPLAY_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>PEBuildStage</key>
	<string>$STAGE</string>
	<key>PERadeon9800Experiment</key>
	<$([ "$R350_EXPERIMENT" = 1 ] && echo true || echo false)/>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>PowerEmu is free software under the GNU GPL v2 or later.</string>
	<!-- The WebAccelerator proxy fetches the guest's web traffic on the host,
	     where App Transport Security otherwise refuses every plaintext http://
	     connection. A 2000s-era guest (Tiger/Leopard) constantly loads http://
	     URLs, and https redirect chains routinely hop through http mirrors
	     (e.g. VideoLAN -> osuosl), so ATS turns those into 502s. The proxy is
	     the deliberate boundary that reaches the legacy web for the guest, so
	     it must be allowed to make insecure connections. -->
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
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
# The hardened runtime is what notarising requires, so it is on for every
# build -- a development build that did not have it would not be exercising
# what a release does, and the first thing to break under it is the
# emulator's JIT, which is the whole machine.  The secure timestamp needs
# Apple's server, so it is only asked for when a release is being cut.
RUNTIME="--options runtime"
TIMESTAMP="--timestamp=none"
[ -n "${POWEREMU_RELEASE:-}" ] && TIMESTAMP="--timestamp"
HELPER="$OUT/Contents/Helpers/PowerEmu VM.app"
if [ "$SIGN" != "-" ]; then
    for f in "$HELPER"/Contents/Frameworks/*.dylib "$HELPER/Contents/MacOS/qemu-img"; do
        [ -f "$f" ] && codesign --force --sign "$SIGN" $TIMESTAMP $RUNTIME "$f" >/dev/null
    done
    codesign --force --sign "$SIGN" $TIMESTAMP $RUNTIME \
        --entitlements "$ROOT/app/Resources/PowerEmuVM.entitlements" \
        "$HELPER/Contents/MacOS/qemu-system-ppc" >/dev/null
    codesign --force --sign "$SIGN" $TIMESTAMP $RUNTIME --entitlements "$ROOT/app/Resources/PowerEmuVM.entitlements" "$HELPER" >/dev/null
fi
codesign --force --sign "$SIGN" $TIMESTAMP $RUNTIME "$OUT/Contents/Helpers/poweremu-netd" >/dev/null
# The helper that holds a guest application's Dock tile.  It was added after
# this list was written and never joined it, so it went out unsigned: no
# Developer ID, no secure timestamp, no hardened runtime.  Everything else in
# the bundle was signed, so nothing looked wrong until Apple refused the whole
# archive over this one file.
codesign --force --sign "$SIGN" $TIMESTAMP $RUNTIME "$OUT/Contents/Helpers/PowerEmuGuestApp" >/dev/null
codesign --force --sign "$SIGN" $TIMESTAMP $RUNTIME --entitlements "$ROOT/app/Resources/PowerEmu.entitlements" "$OUT/Contents/MacOS/PowerEmu" >/dev/null
if [ "${POWEREMU_SMP:-0}" = 1 ]; then
    # Hash the final signed executable: signing changes its bytes. This record
    # is outside the nested helper to avoid a circular signature dependency.
    [ -n "${POWEREMU_QEMU_BINARY:-}" ] && [ -n "${POWEREMU_OPENBIOS:-}" ] || {
        echo "SMP packaging requires explicit backend and firmware paths" >&2; exit 1;
    }
    backend_hash=$(shasum -a 256 "$HELPER/Contents/MacOS/qemu-system-ppc" | cut -d ' ' -f1)
    firmware_hash=$(shasum -a 256 "$HELPER/Contents/Resources/firmware/openbios-ppc" | cut -d ' ' -f1)
    printf '{"version":1,"backendSHA256":"%s","firmwareSHA256":"%s"}\n' "$backend_hash" "$firmware_hash" \
        > "$OUT/Contents/Resources/PowerEmu VM.app.smp.json"
fi
codesign --force --sign "$SIGN" $TIMESTAMP $RUNTIME --entitlements "$ROOT/app/Resources/PowerEmu.entitlements" "$OUT" >/dev/null
echo "signed: $SIGN"
echo "built $OUT ($(du -sh "$OUT" | cut -f1))"
