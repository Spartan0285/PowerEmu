#!/bin/sh
# Validate the actual custom-installer payload, not just its outer package.
set -eu
root=${1:?usage: check-tools-executables.sh TOOLS_DIRECTORY}
install="$root/Install PowerEmu Tools.pkg/Contents/Resources/Install PowerEmu Tools.app"
uninstall="$root/Uninstall PowerEmu Tools.pkg/Contents/Resources/Uninstall PowerEmu Tools.app"
for executable in \
    "$install/Contents/MacOS/Install PowerEmu Tools" \
    "$install/Contents/Resources/PowerEmu Agent.app/Contents/MacOS/PowerEmu Agent" \
    "$install/Contents/Resources/PowerEmuClock" \
    "$uninstall/Contents/MacOS/Uninstall PowerEmu Tools"; do
    if [ ! -f "$executable" ] || [ ! -x "$executable" ] || [ -L "$executable" ]; then
        echo "Tools payload is missing an executable or its execute permission: $executable" >&2
        exit 1
    fi
done
