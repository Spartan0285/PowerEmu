#!/bin/bash
# Copy the kext and the transport test into a running guest.
#   scripts/push-guest-gpu.sh [ssh-port]      (default 2222, the app's VM)
# Nothing here needs a password; loading the kext does, and that is yours.
set -e
cd "$(dirname "$0")/.."
port=${1:-2222}
S=(-p "$port" -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
   -o KexAlgorithms=+diffie-hellman-group14-sha1 -o Ciphers=+aes128-cbc
   -o MACs=+hmac-sha1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
   -i "${TIGER_KEY:-$HOME/.ssh/tiger_key}")
[ -x guest/gld/build/petest ] || { echo "no guest/gld/build/petest" >&2; exit 1; }
[ -d guest/gpu/build/PowerEmuGPU.kext ] || { echo "no kext built" >&2; exit 1; }
scp "${S[@]}" guest/gld/build/petest adam@127.0.0.1:/tmp/petest
# scp -r would follow the bundle fine, but ditto keeps the modes right.
tar -cf - -C guest/gpu/build PowerEmuGPU.kext |
    ssh "${S[@]}" adam@127.0.0.1 'cd /tmp && rm -rf PowerEmuGPU.kext && tar -xf -'
ssh "${S[@]}" adam@127.0.0.1 'chmod +x /tmp/petest; ls -d /tmp/petest /tmp/PowerEmuGPU.kext'
echo
echo "In the guest, as yourself (these need your password, so type them there):"
echo "  sudo chown -R root:wheel /tmp/PowerEmuGPU.kext"
echo "  sudo kextload -t -v 6 /tmp/PowerEmuGPU.kext"
echo "  sudo kextload -v /tmp/PowerEmuGPU.kext"
echo "  /tmp/petest"
