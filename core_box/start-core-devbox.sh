#!/bin/bash
set -e

# Ensure the USERNAME environment variable is set
if [ -z "$USERNAME" ]; then
    echo "ERROR: USERNAME is not set."
    exit 1
fi

# Fix the docker socket permissions so the 'docker' group can use it
if [ -e /var/run/docker.sock ]; then
    sudo chmod 666 /var/run/docker.sock
fi

# Ensure the home directory exists with correct ownership
if [ ! -d "/home/$USERNAME" ]; then
    mkdir -p "/home/$USERNAME"
    chown "$USERNAME:$USERNAME" "/home/$USERNAME"
    chmod 755 "/home/$USERNAME"
fi

# Ensure the .ssh directory exists
mkdir -p "/home/$USERNAME/.ssh"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
chmod 700 "/home/$USERNAME/.ssh"

# Ensure SSH authorized_keys file exists before copying
if [ -f "/etc/ssh_keys/authorized_keys" ]; then
    cp -f "/etc/ssh_keys/authorized_keys" "/home/$USERNAME/.ssh/authorized_keys"
    chown "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh/authorized_keys"
    chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
    echo "SSH public key copied for $USERNAME"
else
    echo "WARNING: /etc/ssh_keys/authorized_keys does not exist. SSH keys not copied."
fi

# Ensure SSH private key file exists before copying
if [ -f "/etc/ssh_keys/id_rsa" ]; then
    cp -f "/etc/ssh_keys/id_rsa" "/home/$USERNAME/.ssh/id_rsa"
    chown "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh/id_rsa"
    chmod 600 "/home/$USERNAME/.ssh/id_rsa"
    echo "SSH private key copied for $USERNAME"
else
    echo "WARNING: /etc/ssh_keys/id_rsa does not exist. Private key not copied."
fi

# Get the default gateway IP (host IP from container's perspective)
HOST_IP=$(ip route | awk '/default/ { print $3 }')

# Add to /etc/hosts if not already present
if ! grep -q "host.docker.internal" /etc/hosts; then
  echo "$HOST_IP host.docker.internal host" >> /etc/hosts
fi

echo "core-devbox: starting ssh service"
# Start SSH service
service ssh start

echo "core-devbox: keep the container running"
# Keep the container running
exec tail -f /dev/null
