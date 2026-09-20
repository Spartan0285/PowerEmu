#!/bin/bash
# Guest hot-code profiling with the pehot QEMU plugin.
#
#   profile-guest.sh on [VM]     load the plugin the next time the VM starts
#   profile-guest.sh off [VM]    stop loading it
#   profile-guest.sh reset       zero the counters (start of the window)
#   profile-guest.sh dump        write the profile, then report it
#   profile-guest.sh map NAME    guest address map for a process, by name
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
map)
    # The profile is addresses; this is what turns them into library names.
    # Taken while the process is still running, because the map dies with it.
    name="${2:?usage: profile-guest.sh map <process name substring>}"
    out="$CTL.vmmap.txt"
    GUEST_PORT="${GUEST_PORT:-2222}" bash "$(dirname "$0")/gsh.sh" \
        "p=\$(ps -axo pid,command | grep -i '$name' | grep -v grep |
              head -1 | awk '{print \$1}');
         [ -n \"\$p\" ] || { echo 'no such process' >&2; exit 1; };
         echo \"process \$p\"; vmmap \$p 2>/dev/null" > "$out"
    echo "$(grep -c . "$out") lines -> $out"
    ;;
*)
    sed -n '2,11p' "$0"; exit 1;;
esac
