#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${USERNAME:-}" ]]; then
    echo "ERROR: USERNAME is not set."
    exit 1
fi

if [[ ! -S /run/podman/podman.sock ]]; then
    echo "ERROR: The rootless Podman socket is not mounted at /run/podman/podman.sock."
    exit 1
fi

AUTHORIZED_KEYS_SOURCE="/run/wsl-devbox/authorized_keys.pub"
if [[ ! -r "$AUTHORIZED_KEYS_SOURCE" ]]; then
    echo "ERROR: The SSH public key mount is missing: $AUTHORIZED_KEYS_SOURCE"
    exit 1
fi

USER_HOME="/home/$USERNAME"
install -d -o "$USERNAME" -g "$USERNAME" -m 0755 "$USER_HOME"
install -d -o "$USERNAME" -g "$USERNAME" -m 0700 "$USER_HOME/.ssh"
install -o "$USERNAME" -g "$USERNAME" -m 0600 "$AUTHORIZED_KEYS_SOURCE" "$USER_HOME/.ssh/authorized_keys"

echo "core-devbox: starting SSH service"
service ssh start

echo "core-devbox: waiting for the remote rootless Podman service"
if ! runuser -u "$USERNAME" -- /usr/local/bin/podman info >/dev/null; then
    echo "ERROR: The DevBox cannot connect to the WSL user's Podman socket."
    exit 1
fi

echo "core-devbox: keeping the container running"
exec tail -f /dev/null
