#!/bin/sh
exec ssh -p 2222 -i ${POWEREMU_GUEST_KEY:-$HOME/.ssh/poweremu_guest} -o BatchMode=yes -o ConnectTimeout=60 -o ServerAliveInterval=30 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1 -o Ciphers=+aes128-cbc -o MACs=+hmac-sha1 -o StrictHostKeyChecking=accept-new adam@127.0.0.1 "$@"
