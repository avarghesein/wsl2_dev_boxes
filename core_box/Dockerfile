# Use Ubuntu 24.04 as the core development image
FROM ubuntu:24.04

# Set build arguments (default username = devuser, default UID/GID = 1001)
ARG USERNAME=devuser
ARG UID=1001
ARG GID=1001
ARG PASSWORD=wsl

# Make USERNAME available in the container runtime environment
ENV USERNAME=$USERNAME

# Use HTTPS for every APT source before installing packages.
RUN find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i 's|http://|https://|g' {} +

# Install the Docker CE client so the container can use the Docker CE daemon
# running in the default Ubuntu WSL distribution through /var/run/docker.sock.
# The minimal Ubuntu base image does not contain CA certificates yet. Bootstrap
# the certificate package over HTTPS with verification disabled only for this
# first transaction; all later APT and repository operations use normal HTTPS
# certificate verification.
RUN apt-get -o Acquire::https::Verify-Peer=false \
    -o Acquire::https::Verify-Host=false update && \
    apt-get -o Acquire::https::Verify-Peer=false \
    -o Acquire::https::Verify-Host=false install -y ca-certificates curl && \
    update-ca-certificates
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" > /etc/apt/sources.list.d/docker.list

# Install necessary packages
RUN apt update && apt install -y \
    openssh-server \
    sudo \
    docker-ce-cli \
    git \
    rsync \
    python3.12 python3.12-venv python3.12-dev python3-pip \
    net-tools iputils-ping htop

# Create the user with the specified UID/GID and set password
RUN groupadd -g $GID $USERNAME && \
    useradd -m -u $UID -g $GID -s /bin/bash $USERNAME && \
    echo "$USERNAME:$PASSWORD" | chpasswd && \
    usermod -aG sudo $USERNAME && \
    groupadd -f docker && \
    usermod -aG docker $USERNAME

RUN echo "sudo chmod 666 /var/run/docker.sock" >> /home/$USERNAME/.bashrc

# Allow sudo without password
RUN echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME && chmod 0440 /etc/sudoers.d/$USERNAME

# Configure SSH access
RUN mkdir -p /home/$USERNAME/.ssh && \
    chmod 700 /home/$USERNAME/.ssh

# Copy SSH public key to a safe location (so it persists)
RUN mkdir -p /etc/ssh_keys/ && \
    chown -R $USERNAME:$USERNAME /etc/ssh_keys/ 

COPY keys/wsl-dev-container-key /etc/ssh_keys/id_rsa
COPY keys/wsl-dev-container-key.pub /etc/ssh_keys/authorized_keys

RUN chmod 600 /etc/ssh_keys/id_rsa && \
    chmod 600 /etc/ssh_keys/authorized_keys && \
    chown -R $USERNAME:$USERNAME /etc/ssh_keys/

# Configure SSH for key-based authentication
RUN mkdir /var/run/sshd && \
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config && \
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config && \
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config

# Set hostname
RUN echo "wsl-dev" > /etc/hostname

# Copy the core container startup script
COPY start-core-devbox.sh /start-core-devbox.sh
RUN chmod +x /start-core-devbox.sh

# Start the core DevBox
ENTRYPOINT ["/start-core-devbox.sh"]
