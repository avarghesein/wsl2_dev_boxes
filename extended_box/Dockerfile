FROM core_box:latest

# Set build arguments (default username = devuser, default UID/GID = 1001)
ARG USERNAME=devuser
ARG UID=1001
ARG GID=1001
ARG PASSWORD=wsl
# Make USERNAME available in the container runtime environment
ENV USERNAME=$USERNAME

RUN mkdir -p /wsl/envs && \
    chown -R $USERNAME:$USERNAME /wsl

RUN chmod -R a+rw /wsl/envs/

# Switch to the non-root user
USER $USERNAME

COPY python-requirements.txt /wsl/envs/extended.requirements.txt

RUN python3 -m venv /wsl/envs/extended && \
    /bin/bash -c "source /wsl/envs/extended/bin/activate && \
    pip install --upgrade pip && \
    pip install -r /wsl/envs/extended.requirements.txt"

# Switch back to root to perform other system-wide operations if needed
USER root

# Set hostname
RUN echo "extended_box" > /etc/hostname

# Copy the extended container startup script
COPY start_extended_devbox.sh /start_extended_devbox.sh
RUN chmod +x /start_extended_devbox.sh

# Start the extended DevBox
ENTRYPOINT ["/start_extended_devbox.sh"]
