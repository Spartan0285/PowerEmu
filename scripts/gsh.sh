#!/bin/bash
# gsh.sh CMD... : run a command in the benchmark guest (see measure.sh).
# The key is not in the repo: TIGER_KEY, or ~/.ssh/tiger_key.
exec ssh -p ${GUEST_PORT:-2299} -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -o KexAlgorithms=+diffie-hellman-group14-sha1 -o Ciphers=+aes128-cbc -o MACs=+hmac-sha1 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
  -i "${TIGER_KEY:-$HOME/.ssh/tiger_key}" adam@127.0.0.1 "$@"
