#!/bin/bash
# Copy the kext and the transport test into a running guest.
#   scripts/push-guest-gpu.sh [ssh-port]      (default 2222, the app's VM)
# Nothing here needs a password; loading the kext does, and that is yours.
set -e
cd "$(dirname "$0")/.."
port=${1:-2222}
# ssh spells the port -p and scp spells it -P, so it is not in the shared list.
S=(-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
   -o KexAlgorithms=+diffie-hellman-group14-sha1 -o Ciphers=+aes128-cbc
   -o MACs=+hmac-sha1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
   -i "${TIGER_KEY:-$HOME/.ssh/tiger_key}")
# A forwarded port accepts connections whether or not the guest is listening
# -- slirp answers either way -- so ask ssh, which needs the guest's sshd.
if ! ssh -p "$port" "${S[@]}" -o BatchMode=yes -o ConnectTimeout=8 \
        adam@127.0.0.1 true 2>/dev/null; then
    echo "push-guest-gpu: no guest answering on port $port." >&2
    echo "  Start the Tiger VM in PowerEmu first, and wait for the desktop." >&2
    echo "  If the app picked a different port, pass it: $0 <port>" >&2
    exit 1
fi
[ -x guest/gld/build/petest ] || { echo "no guest/gld/build/petest" >&2; exit 1; }
[ -d guest/gpu/build/PowerEmuGPU.kext ] || { echo "no kext built" >&2; exit 1; }
scp -P "$port" "${S[@]}" guest/gld/build/petest adam@127.0.0.1:/tmp/petest
# Once the kext has been chowned to root:wheel for kextload, this user can no
# longer replace it -- /tmp is sticky. That is not a failure if what is
# already there is what we would have sent, so compare first and say so.
want=$(openssl sha1 guest/gpu/build/PowerEmuGPU.kext/Contents/MacOS/PowerEmuGPU |
       sed 's/.*= //')
have=$(ssh -p "$port" "${S[@]}" adam@127.0.0.1 \
       'openssl sha1 /tmp/PowerEmuGPU.kext/Contents/MacOS/PowerEmuGPU 2>/dev/null |
        sed "s/.*= //"' 2>/dev/null)
if [ "$want" = "$have" ]; then
    echo "kext already in the guest and identical, leaving it alone"
else
    tar -cf - -C guest/gpu/build PowerEmuGPU.kext |
        ssh -p "$port" "${S[@]}" adam@127.0.0.1 \
            'cd /tmp && rm -rf PowerEmuGPU.kext && tar -xf -'
fi
ssh -p "$port" "${S[@]}" adam@127.0.0.1 'chmod +x /tmp/petest; ls -d /tmp/petest /tmp/PowerEmuGPU.kext'
echo
echo "In the guest, as yourself (these need your password, so type them there):"
echo "  sudo chown -R root:wheel /tmp/PowerEmuGPU.kext"
echo "  sudo kextload -t -v 6 /tmp/PowerEmuGPU.kext"
echo "  sudo kextload -v /tmp/PowerEmuGPU.kext"
echo "  /tmp/petest"
