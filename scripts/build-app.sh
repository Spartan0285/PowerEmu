#!/bin/bash
# build-app.sh : build PowerEmu.app into build/
#   PowerEmu.app/Contents/MacOS/PowerEmu               the SwiftUI app
#   PowerEmu.app/Contents/Helpers/PowerEmu VM.app      QEMU + libraries + firmware
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/PowerEmu.app"
VERSION=0.1

(cd "$ROOT/app" && swift build -c release)
BIN="$(cd "$ROOT/app" && swift build -c release --show-bin-path)/PowerEmu"

[ -d "$ROOT/build/PowerEmu VM.app" ] || "$ROOT/scripts/bundle-qemu.sh" "$ROOT/build/PowerEmu VM.app"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Helpers" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/PowerEmu"
ditto "$ROOT/build/PowerEmu VM.app" "$OUT/Contents/Helpers/PowerEmu VM.app"
cp "$ROOT/LICENSE" "$ROOT/COPYING" "$ROOT/THIRD-PARTY-NOTICES.md" "$OUT/Contents/Resources/"
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
	<string>$VERSION</string>
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

# The helper is already signed; sign the outer app around it.
codesign --force --sign - "$OUT/Contents/MacOS/PowerEmu" >/dev/null
codesign --force --sign - "$OUT" >/dev/null
echo "built $OUT ($(du -sh "$OUT" | cut -f1))"
