#!/bin/sh
# Run on the PowerBook after make all. Legacy bundle packages open in Tiger's
# native Installer, with separate install/removal products and receipts.
set -eu
cd "$(dirname "$0")/.."
version=$(sed -n 's/^#define PE_AGENT_VERSION "\([^"]*\)"/\1/p' src/PEAgent.m)
work=$(mktemp -d /tmp/pe-packages.XXXXXX)
trap 'rm -rf "$work"' EXIT
for action in Install Uninstall; do
    mkdir -p "$work/$action/root" "$work/$action/resources" "$work/$action/scripts"
    ditto "build/$action PowerEmu Tools.app" "$work/$action/resources/$action PowerEmu Tools.app"
    cp Resources/PowerEmu.icns "$work/$action/resources/PowerEmu.icns"
    /usr/bin/sips -s format png Resources/PowerEmu.icns --out "$work/$action/resources/PowerEmu.png" >/dev/null
    cat > "$work/$action/resources/Welcome.html" <<HTML
<html><body><img src="PowerEmu.png" width="64" height="64"><h1>$action PowerEmu Tools $version</h1>
HTML
    if [ "$action" = Install ]; then
        cat >> "$work/$action/resources/Welcome.html" <<'HTML'
<p>Install Harmony window integration, shared clipboard, shared folders and clock synchronization for the logged-in guest account. Tools start automatically at login.</p>
<p>An administrator password enables window control. Installing again updates or repairs Tools. To remove Tools, use the separate Uninstall PowerEmu Tools package.</p>
HTML
    else
        cat >> "$work/$action/resources/Welcome.html" <<'HTML'
<p>This package removes PowerEmu Tools from the logged-in guest account and removes the optional clock service. Harmony, shared clipboard and guest integration will stop working.</p>
<p>Quit Installer to cancel. Continue only if you want to uninstall Tools.</p>
HTML
    fi
    printf '</body></html>\n' >> "$work/$action/resources/Welcome.html"
    cat > "$work/$action/scripts/preflight" <<'SCRIPT'
#!/bin/sh
set -eu
[ "${3:-/}" = / ] || { echo 'Install on the running guest system only.' >&2; exit 1; }
[ "$(/usr/bin/stat -f %u /dev/console)" != 0 ] || { echo 'Log into the guest desktop before running this package.' >&2; exit 1; }
SCRIPT
    cp "$work/$action/scripts/preflight" "$work/$action/scripts/postflight"
    if [ "$action" = Install ]; then
        cat >> "$work/$action/scripts/postflight" <<'SCRIPT'
resources=$(dirname "$0")
# Window control is a system accessibility setting on Tiger/Leopard.
touch /var/db/.AccessibilityAPIEnabled
chmod 444 /var/db/.AccessibilityAPIEnabled
mkdir -p /Library/PowerEmu /Library/LaunchDaemons
cp "$resources/Install PowerEmu Tools.app/Contents/Resources/PowerEmuClock" /Library/PowerEmu/PowerEmuClock
cp "$resources/Install PowerEmu Tools.app/Contents/Resources/com.spartan0285.poweremu.clock.plist" /Library/LaunchDaemons/com.spartan0285.poweremu.clock.plist
chown root:wheel /Library/PowerEmu/PowerEmuClock /Library/LaunchDaemons/com.spartan0285.poweremu.clock.plist
chmod 755 /Library/PowerEmu/PowerEmuClock
chmod 644 /Library/LaunchDaemons/com.spartan0285.poweremu.clock.plist
unset LAUNCHD_SOCKET
/usr/bin/perl -e '$< = $>; exec @ARGV' /bin/launchctl unload /Library/LaunchDaemons/com.spartan0285.poweremu.clock.plist 2>/dev/null || true
/usr/bin/perl -e '$< = $>; exec @ARGV' /bin/launchctl load /Library/LaunchDaemons/com.spartan0285.poweremu.clock.plist
"$resources/Install PowerEmu Tools.app/Contents/MacOS/Install PowerEmu Tools" --package-install
SCRIPT
    else
        cat >> "$work/$action/scripts/postflight" <<'SCRIPT'
resources=$(dirname "$0")
"$resources/Uninstall PowerEmu Tools.app/Contents/MacOS/Uninstall PowerEmu Tools" --package-uninstall
# Remove only this product's optional service, never a shared directory.
unset LAUNCHD_SOCKET
/usr/bin/perl -e '$< = $>; exec @ARGV' /bin/launchctl unload /Library/LaunchDaemons/com.spartan0285.poweremu.clock.plist 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.spartan0285.poweremu.clock.plist /Library/PowerEmu/PowerEmuClock
# Accessibility may be used by other applications; deliberately leave it enabled.
SCRIPT
    fi
    chmod 755 "$work/$action/scripts/"*
    lower=$(echo "$action" | tr 'A-Z' 'a-z')
    out="build/$action PowerEmu Tools.pkg"
    rm -rf "$out"
    /Developer/usr/bin/packagemaker --root "$work/$action/root" --out "$out" \
        --id "com.spartan0285.poweremu.tools-$lower" --version "$version" \
        --title "$action PowerEmu Tools" --target 10.4 --domain system --install-to / \
        --resources "$work/$action/resources" --scripts "$work/$action/scripts" --root-volume-only
    /usr/libexec/PlistBuddy -c 'Set :IFPkgFlagAuthorizationAction RootAuthorization' "$out/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string PowerEmu.icns' "$out/Contents/Info.plist"
done
