#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
template=${1:?pass signed GuestApplication.app}
host=${2:?pass signed PowerEmu.app}
output=${3:-"$repo/build/GuestLauncherTrustChecks.app"}
identifier=com.spartan0285.poweremu.guestapp.0123456789abcdef0123456789abcdef
executable=GuestLauncherTrustChecks
case "$output" in
  "$repo"/build/*) ;;
  *) echo "output must be a disposable path under $repo/build" >&2; exit 2 ;;
esac

rm -rf "$output"
mkdir -p "$output/Contents/MacOS"
cat > "$output/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$executable</string>
  <key>CFBundleIdentifier</key><string>$identifier</string>
  <key>CFBundleName</key><string>Guest Launcher Trust Checks</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -parse-as-library \
  "$repo/app/Sources/PowerEmu/GuestLauncherTrust.swift" \
  "$repo/tests/GuestLauncherTrust/main.swift" \
  -o "$output/Contents/MacOS/$executable"
chmod 755 "$output/Contents/MacOS/$executable"
codesign --force --sign - --options runtime --identifier "$identifier" "$output"
result="$repo/build/GuestLauncherTrustChecks.result"
rm -f "$result"
"$output/Contents/MacOS/$executable" "$template" "$host" "$result"
test -s "$result"
cat "$result"
