#!/bin/bash
set -e

echo "extended-devbox: running core startup"
/start-core-devbox.sh &

echo "extended-devbox: keep the container running"
# Keep the container running
exec tail -f /dev/null
