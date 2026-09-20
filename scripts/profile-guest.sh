#!/bin/bash
# Guest hot-code profiling with the pehot QEMU plugin.
#
#   profile-guest.sh on [VM]     load the plugin the next time the VM starts
#   profile-guest.sh off [VM]    stop loading it
#   profile-guest.sh reset       zero the counters (start of the window)
#   profile-guest.sh dump        write the profile, then report it
#
# The plugin is in the QEMU build tree; "on" points the VM's config at it.
set -e
VM="${2:-Tiger}"
CFG="$HOME/Library/Application Support/PowerEmu/Virtual Machines/$VM.poweremu/config.plist"
QEMU="${POWEREMU_QEMU:-$HOME/Developer/poweremu-qemu}"
PLUGIN="$QEMU/build/contrib/plugins/libpehot.dylib"
CTL="$HOME/Library/Application Support/PowerEmu/pehot"

case "$1" in
on)
    [ -f "$PLUGIN" ] || { echo "build it: ninja -C $QEMU/build contrib/plugins/libpehot.dylib"; exit 1; }
    /usr/libexec/PlistBuddy -c "Delete :extraQEMUArgs" "$CFG" 2>/dev/null || true
    /usr/libexec/PlistBuddy \
        -c "Add :extraQEMUArgs array" \
        -c "Add :extraQEMUArgs:0 string -plugin" \
        -c "Add :extraQEMUArgs:1 string $PLUGIN,ctl=$CTL" "$CFG"
    echo "profiling armed for $VM (ctl $CTL)"
    ;;
off)
    /usr/libexec/PlistBuddy -c "Delete :extraQEMUArgs" "$CFG" 2>/dev/null || true
    echo "profiling off for $VM"
    ;;
reset)
    touch "$CTL.reset"; sleep 1
    [ -f "$CTL.reset" ] && echo "plugin not listening (is the VM running with profiling on?)" || echo "counters reset"
    ;;
dump)
    n=$(ls "$CTL".*.raw 2>/dev/null | wc -l | tr -d ' ')
    touch "$CTL.dump"; sleep 2
    f="$CTL.$((n + 1)).raw"
    [ -f "$f" ] || { echo "no dump appeared"; exit 1; }
    python3 "$QEMU/scripts/pehot-report.py" "$f" "${3:-40}" | tee "${f%.raw}.txt"
    echo "--- saved ${f%.raw}.txt"
    ;;
*)
    sed -n '2,10p' "$0"; exit 1;;
esac
