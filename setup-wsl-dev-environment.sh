#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage:
  setup-wsl-dev-environment.sh --username <linux-user> --box <blueprint-folder> [--instance <name>] [--yes] [--update] [--remove]

Options:
  -u, --username  WSL user and DevBox user name.
  -b, --box       Blueprint folder. Omit only when creating the core box.
  -i, --instance  Optional named instance using the selected box image.
  -y, --yes       Replace existing Podman resources without prompting.
      --update    Recreate a container from its existing image and current configuration.
      --remove    Remove the selected box resources instead of building a container.
  -h, --help      Show this help.
HELP
}

USERNAME=""
BOX=""
INSTANCE=""
AUTO_CONFIRM=0
UPDATE_ONLY=0
REMOVE_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--username)
            [[ $# -ge 2 ]] || { echo "ERROR: --username requires a value."; exit 1; }
            USERNAME="$2"
            shift 2
            ;;
        -b|--box)
            [[ $# -ge 2 ]] || { echo "ERROR: --box requires a value."; exit 1; }
            BOX="$2"
            shift 2
            ;;
        -i|--instance)
            [[ $# -ge 2 ]] || { echo "ERROR: --instance requires a value."; exit 1; }
            INSTANCE="$2"
            shift 2
            ;;
        -y|--yes|--force)
            AUTO_CONFIRM=1
            shift
            ;;
        --update)
            UPDATE_ONLY=1
            shift
            ;;
        --remove)
            REMOVE_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ "$UPDATE_ONLY" -eq 1 && "$REMOVE_ONLY" -eq 1 ]]; then
    echo "ERROR: --update and --remove cannot be used together."
    exit 1
fi
if [[ -z "$USERNAME" ]]; then
    echo "ERROR: --username is required."
    usage
    exit 1
fi
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || [[ "$USERNAME" == "root" ]]; then
    echo "ERROR: Username must be a valid non-root Linux username for rootless Podman."
    exit 1
fi
if [[ -n "$INSTANCE" ]] && ! [[ "$INSTANCE" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; then
    echo "ERROR: Instance must start with a lowercase letter or number and contain only lowercase letters, numbers, '.', '_' or '-'."
    exit 1
fi
if [[ -n "$INSTANCE" && -z "$BOX" ]]; then
    echo "ERROR: --instance requires --box."
    exit 1
fi
if [[ -n "$BOX" ]] && ! [[ "$BOX" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    echo "ERROR: --box must exactly match a lowercase blueprint folder name and contain only letters, numbers, '-' or '_'."
    exit 1
fi
if [[ "$BOX" == "core_box" ]]; then
    echo "ERROR: core_box is reserved for the shared foundation image."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_USER="$(id -un)"
if [[ "$CURRENT_USER" != "$USERNAME" ]]; then
    echo "ERROR: Run this script as WSL user '$USERNAME'; current user is '$CURRENT_USER'."
    exit 1
fi

USER_ENTRY="$(getent passwd "$USERNAME")" || {
    echo "ERROR: WSL user '$USERNAME' does not exist. Run Host mode first."
    exit 1
}
IFS=: read -r _ _ WSL_UID WSL_GID _ WSL_HOME _ <<< "$USER_ENTRY"
if [[ -z "$WSL_HOME" || ! -d "$WSL_HOME" ]]; then
    echo "ERROR: Could not find the WSL home directory for '$USERNAME'."
    exit 1
fi
if [[ "$(id -u)" -ne "$WSL_UID" ]]; then
    echo "ERROR: This script must run in the configured user's rootless session."
    exit 1
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$WSL_UID}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: Podman is not installed in Ubuntu WSL. Run Host mode first."
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required to read box configuration."
    exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
    echo "ERROR: systemd is required for rootless Podman box startup."
    exit 1
fi

ROOTLESS_STATE="$(env -u CONTAINER_HOST -u CONTAINER_CONNECTION podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
if [[ "$ROOTLESS_STATE" != "true" ]]; then
    echo "ERROR: Podman is not available as a rootless engine for '$USERNAME'."
    echo "Start Ubuntu WSL as '$USERNAME' and run Host mode to configure rootless Podman."
    exit 1
fi

if ! systemctl --user enable --now podman.socket >/dev/null; then
    echo "ERROR: Could not start the rootless Podman API socket for '$USERNAME'."
    echo "Check that systemd is enabled in WSL and user lingering is enabled."
    exit 1
fi

SSH_DIR="$WSL_HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
cp "$SCRIPT_DIR/core_box/keys/wsl-dev-container-key" "$SSH_DIR/"
cp "$SCRIPT_DIR/core_box/keys/wsl-dev-container-key.pub" "$SSH_DIR/"
chmod 600 "$SSH_DIR/wsl-dev-container-key"
SSH_PRIVATE_KEY="$SSH_DIR/wsl-dev-container-key"
SSH_PUBLIC_KEY="$SSH_PRIVATE_KEY.pub"

BUILD_DIR="core_box"
CONFIG_FILE_PATH="core_box/config.json"
if [[ -n "$BOX" ]]; then
    BUILD_DIR="$BOX"
    CONFIG_FILE_PATH="$BOX/config.json"
fi
if [[ ! -d "$SCRIPT_DIR/$BUILD_DIR" ]]; then
    echo "ERROR: Box directory does not exist: $SCRIPT_DIR/$BUILD_DIR"
    exit 1
fi

if [[ -z "$BOX" ]]; then
    CONTAINER_NAME="core_box"
    IMAGE_NAME="localhost/core_box:latest"
    HOST_ALIAS="core_box"
elif [[ -n "$INSTANCE" ]]; then
    CONTAINER_NAME="$BOX-$INSTANCE"
    IMAGE_NAME="localhost/$BOX:latest"
    HOST_ALIAS="$BOX-$INSTANCE"
else
    CONTAINER_NAME="$BOX"
    IMAGE_NAME="localhost/$BOX:latest"
    HOST_ALIAS="$BOX"
fi

QUADLET_DIR="$WSL_HOME/.config/containers/systemd"
QUADLET_FILE="$QUADLET_DIR/$CONTAINER_NAME.container"
SYSTEMD_UNIT="$CONTAINER_NAME.service"

podman_local() {
    env -u CONTAINER_HOST -u CONTAINER_CONNECTION podman "$@"
}

remove_container_unit() {
    local name="$1"
    local unit_file="$QUADLET_DIR/$name.container"
    systemctl --user stop "$name.service" >/dev/null 2>&1 || true
    rm -f "$unit_file"
    if podman_local container exists "$name"; then
        podman_local container rm --force "$name" >/dev/null
    fi
}

confirm_or_cancel() {
    local prompt="$1"
    local answer
    if [[ "$AUTO_CONFIRM" -eq 1 ]]; then
        return 0
    fi
    printf '%s [y/N]\n' "$prompt"
    read -r answer
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *)
            echo "Operation cancelled. Existing resources were not changed."
            exit 2
            ;;
    esac
}

if [[ "$REMOVE_ONLY" -eq 1 ]]; then
    [[ -n "$BOX" ]] || { echo "ERROR: --remove requires --box."; exit 1; }
    containers_to_remove=()
    while IFS= read -r existing_container; do
        if [[ "$existing_container" == "$CONTAINER_NAME" ]]; then
            containers_to_remove+=("$existing_container")
        elif [[ -z "$INSTANCE" && "$existing_container" == "$BOX-"* ]]; then
            containers_to_remove+=("$existing_container")
        fi
    done < <(podman_local ps -a --filter label=io.wsl-dev-box.managed=true --format '{{.Names}}')

    quadlet_files_to_remove=()
    if [[ -n "$INSTANCE" ]]; then
        [[ -f "$QUADLET_FILE" ]] && quadlet_files_to_remove+=("$QUADLET_FILE")
    else
        shopt -s nullglob
        for candidate in "$QUADLET_DIR/$BOX.container" "$QUADLET_DIR/$BOX-"*.container; do
            [[ -f "$candidate" ]] && quadlet_files_to_remove+=("$candidate")
        done
        shopt -u nullglob
    fi

    image_exists=0
    if [[ -z "$INSTANCE" ]] && podman_local image exists "$IMAGE_NAME"; then
        image_exists=1
    fi
    if [[ ${#containers_to_remove[@]} -eq 0 && ${#quadlet_files_to_remove[@]} -eq 0 && "$image_exists" -eq 0 ]]; then
        echo "No removable Podman resources found for box '$BOX'."
        exit 0
    fi

    if [[ -n "$INSTANCE" ]]; then
        echo "This removes instance '$CONTAINER_NAME'; the image and persistent WSL volume are retained."
    else
        echo "This removes '$BOX' and its named instances and image. The shared WSL volume is retained."
    fi
    confirm_or_cancel "Continue with removal?"

    for unit_file in "${quadlet_files_to_remove[@]}"; do
        unit_name="$(basename "$unit_file" .container)"
        systemctl --user stop "$unit_name.service" >/dev/null 2>&1 || true
        rm -f "$unit_file"
    done
    systemctl --user daemon-reload
    for container_to_remove in "${containers_to_remove[@]}"; do
        podman_local container rm --force "$container_to_remove" >/dev/null 2>&1 || true
    done
    if [[ "$image_exists" -eq 1 ]]; then
        podman_local image rm "$IMAGE_NAME"
    fi
    echo "Removal completed."
    exit 0
fi

if [[ ! -f "$SSH_PUBLIC_KEY" ]]; then
    echo "ERROR: Repository SSH public key is missing from $SSH_PUBLIC_KEY."
    exit 1
fi

CONFIG_FILES=()
MOUNT_CONFIG_FILES=("$SCRIPT_DIR/core_box/config.json")
if [[ -n "$BOX" ]]; then
    MOUNT_CONFIG_FILES+=("$SCRIPT_DIR/$BOX/config.json")
    if [[ -n "$INSTANCE" ]]; then
        INSTANCE_CONFIG_FILE_PATH="$BOX/instances/$INSTANCE/config.json"
        if [[ ! -f "$SCRIPT_DIR/$INSTANCE_CONFIG_FILE_PATH" ]]; then
            echo "ERROR: Instance configuration not found: $SCRIPT_DIR/$INSTANCE_CONFIG_FILE_PATH"
            exit 1
        fi
        CONFIG_FILE_PATH="$INSTANCE_CONFIG_FILE_PATH"
        CONFIG_FILES=("$SCRIPT_DIR/core_box/config.json" "$SCRIPT_DIR/$CONFIG_FILE_PATH")
        MOUNT_CONFIG_FILES+=("$SCRIPT_DIR/$CONFIG_FILE_PATH")
    else
        CONFIG_FILES=("$SCRIPT_DIR/core_box/config.json" "$SCRIPT_DIR/$CONFIG_FILE_PATH")
    fi
else
    CONFIG_FILES=("$SCRIPT_DIR/core_box/config.json")
fi

for config_file in "${CONFIG_FILES[@]}" "${MOUNT_CONFIG_FILES[@]}"; do
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Configuration file not found: $config_file"
        exit 1
    fi
    jq empty "$config_file"
done

SSH_PORT="$(jq -r '.ssh_port // empty' "$SCRIPT_DIR/$CONFIG_FILE_PATH")"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    echo "ERROR: $CONFIG_FILE_PATH must define ssh_port between 1 and 65535."
    exit 1
fi

SSH_CONFIG="$SSH_DIR/config"
touch "$SSH_CONFIG"
SSH_CONFIG_TEMP="$(mktemp "${SSH_CONFIG}.XXXXXX")"
awk -v host_alias="$HOST_ALIAS" -v username="$USERNAME" -v ssh_port="$SSH_PORT" -v private_key="$SSH_PRIVATE_KEY" '
    function write_host_entry() {
        print "Host " host_alias
        print "    HostName localhost"
        print "    User " username
        print "    Port " ssh_port
        print "    IdentityFile \"" private_key "\""
        print "    IdentitiesOnly yes"
        print ""
    }
    /^[[:space:]]*Host[[:space:]]/ {
        in_target=0
        if ($1 == "Host" && NF == 2 && $2 == host_alias) {
            in_target=1
            if (!entry_written) {
                write_host_entry()
                entry_written=1
            }
            next
        }
    }
    in_target { next }
    { print }
    END {
        if (!entry_written) write_host_entry()
    }
' "$SSH_CONFIG" > "$SSH_CONFIG_TEMP"
chmod 0600 "$SSH_CONFIG_TEMP"
mv -f "$SSH_CONFIG_TEMP" "$SSH_CONFIG"
echo "Updated Ubuntu SSH host '$HOST_ALIAS'."
ssh-keygen -f "$SSH_DIR/known_hosts" -R "[localhost]:$SSH_PORT" 2>/dev/null || true

build_image() {
    local image_directory="$1"
    local image_name="$2"
    local -a build_args=(--build-arg "USERNAME=$USERNAME")

    if [[ "$image_directory" == "core_box" ]]; then
        build_args+=(--build-arg "UID=$WSL_UID" --build-arg "GID=$WSL_GID")
        build_args+=(--label "io.wsl-dev-box.core-runtime=remote-socket-v1")
    fi

    echo "Building image '$image_name' with Podman..."
    podman_local build --progress=plain "${build_args[@]}" \
        -t "$image_name" \
        -f "$SCRIPT_DIR/$image_directory/Containerfile" "$SCRIPT_DIR/$image_directory"
}

write_quadlet_value() {
    local key="$1"
    local value="$2"
    # Quadlet's multi-value Volume parser preserves surrounding quotes, which
    # makes Podman interpret a final :ro option as ro". Write assignment values
    # without shell-style wrapping quotes and escape systemd specifiers.
    value="${value//%/%%}"
    printf '%s=%s\n' "$key" "$value"
}

IMAGE_EXISTS=0
CONTAINER_EXISTS=0
if podman_local image exists "$IMAGE_NAME"; then IMAGE_EXISTS=1; fi
if podman_local container exists "$CONTAINER_NAME"; then CONTAINER_EXISTS=1; fi

if [[ "$UPDATE_ONLY" -eq 1 ]]; then
    if [[ "$IMAGE_EXISTS" -eq 0 ]]; then
        echo "ERROR: Image '$IMAGE_NAME' does not exist. Run Box mode first."
        exit 1
    fi
    if [[ "$CONTAINER_EXISTS" -eq 1 || -f "$QUADLET_FILE" ]]; then
        echo "Recreating '$CONTAINER_NAME' from its existing image and current configuration..."
        remove_container_unit "$CONTAINER_NAME"
    fi
else
    if [[ -n "$BOX" ]]; then
        core_runtime_version=""
        if podman_local image exists localhost/core_box:latest; then
            core_runtime_version="$(podman_local image inspect --format '{{ index .Labels "io.wsl-dev-box.core-runtime" }}' localhost/core_box:latest 2>/dev/null || true)"
        fi
        if [[ "$core_runtime_version" != "remote-socket-v1" ]]; then
            echo "The core image is missing or needs a runtime refresh. Building localhost/core_box:latest first..."
            build_image core_box localhost/core_box:latest
        fi
    fi

    if [[ -n "$INSTANCE" ]]; then
        if [[ "$IMAGE_EXISTS" -eq 0 ]]; then
            build_image "$BUILD_DIR" "$IMAGE_NAME"
        fi
        if [[ "$CONTAINER_EXISTS" -eq 1 || -f "$QUADLET_FILE" ]]; then
            echo "An existing instance '$HOST_ALIAS' was found. Replacing it removes only this instance container."
            confirm_or_cancel "Continue and replace this instance?"
            remove_container_unit "$CONTAINER_NAME"
        fi
    elif [[ "$IMAGE_EXISTS" -eq 1 || "$CONTAINER_EXISTS" -eq 1 || -f "$QUADLET_FILE" ]]; then
        echo "Existing Podman resources were found for '$HOST_ALIAS'."
        [[ "$IMAGE_EXISTS" -eq 1 ]] && echo "  Image:     $IMAGE_NAME"
        [[ "$CONTAINER_EXISTS" -eq 1 ]] && echo "  Container: $CONTAINER_NAME"
        confirm_or_cancel "Replace these resources?"
        remove_container_unit "$CONTAINER_NAME"
        if [[ "$IMAGE_EXISTS" -eq 1 ]]; then
            podman_local image rm "$IMAGE_NAME"
        fi
    fi

    if [[ -z "$INSTANCE" ]]; then
        build_image "$BUILD_DIR" "$IMAGE_NAME"
    fi
fi

NETWORK_NAME="wsl-network"
VOLUME_NAME="wsl_dev_home"
CONTAINER_MOUNT_PATH="/wsl/shared"
podman_local network exists "$NETWORK_NAME" || podman_local network create "$NETWORK_NAME" >/dev/null
podman_local volume exists "$VOLUME_NAME" || podman_local volume create "$VOLUME_NAME" >/dev/null

PORT_MAPPINGS=()
validate_port_number() {
    local port_number="$1"
    if (( port_number < 1 || port_number > 65535 )); then
        echo "ERROR: Port must be between 1 and 65535: $port_number"
        exit 1
    fi
}

validate_port_mapping() {
    local spec="$1"
    local host_start host_end container_start container_end
    if [[ "$spec" =~ ^([0-9]+):([0-9]+)$ ]]; then
        validate_port_number "${BASH_REMATCH[1]}"
        validate_port_number "${BASH_REMATCH[2]}"
        return
    fi
    if [[ "$spec" =~ ^([0-9]+)-([0-9]+)(:([0-9]+)-([0-9]+))?$ ]]; then
        host_start="${BASH_REMATCH[1]}"
        host_end="${BASH_REMATCH[2]}"
        container_start="${BASH_REMATCH[4]:-$host_start}"
        container_end="${BASH_REMATCH[5]:-$host_end}"
        validate_port_number "$host_start"
        validate_port_number "$host_end"
        validate_port_number "$container_start"
        validate_port_number "$container_end"
        if (( host_start > host_end || container_start > container_end || host_end - host_start != container_end - container_start )); then
            echo "ERROR: Invalid or mismatched port range: $spec"
            exit 1
        fi
        return
    fi
    if [[ "$spec" =~ ^[0-9]+$ ]]; then
        validate_port_number "$spec"
        return
    fi
    echo "ERROR: Invalid port mapping '$spec'. Use HOST:CONTAINER, HOST-RANGE, or HOST-RANGE:CONTAINER-RANGE."
    exit 1
}

for config_file in "${CONFIG_FILES[@]}"; do
    while IFS= read -r port; do
        if [[ -n "$port" ]]; then
            validate_port_mapping "$port"
            PORT_MAPPINGS+=("$port")
        fi
    done < <(jq -r '.ports[]? // empty' "$config_file")
done

MOUNT_SOURCES=("$WSL_HOME")
MOUNT_TARGETS=("$CONTAINER_MOUNT_PATH")
MOUNT_READ_ONLY=("false")
for config_file in "${MOUNT_CONFIG_FILES[@]}"; do
    while IFS=$'\t' read -r source_path target_path read_only; do
        [[ -n "$source_path" || -n "$target_path" ]] || continue
        if [[ -z "$source_path" || -z "$target_path" ]]; then
            echo "ERROR: Each mount must define non-empty source and target paths."
            exit 1
        fi
        if [[ "$source_path" != /* || "$target_path" != /* ]]; then
            echo "ERROR: Mount source and target must be absolute Linux paths: $source_path -> $target_path"
            exit 1
        fi
        if [[ ! -e "$source_path" ]]; then
            echo "ERROR: Bind-mount source does not exist in Ubuntu WSL: $source_path"
            exit 1
        fi
        if [[ "$read_only" != "true" && "$read_only" != "false" ]]; then
            echo "ERROR: Mount read_only must be true or false: $source_path -> $target_path"
            exit 1
        fi
        MOUNT_SOURCES+=("$source_path")
        MOUNT_TARGETS+=("$target_path")
        MOUNT_READ_ONLY+=("$read_only")
    done < <(jq -r '.mounts[]? | [.source // empty, .target // empty, (.read_only // false)] | @tsv' "$config_file")
done

mkdir -p "$QUADLET_DIR"
TEMP_QUADLET="$(mktemp "$QUADLET_DIR/.${CONTAINER_NAME}.XXXXXX")"
{
    printf '[Unit]\nDescription=WSL DevBox %s\nRequires=podman.socket\nAfter=podman.socket\n\n' "$CONTAINER_NAME"
    printf '[Container]\n'
    write_quadlet_value Image "$IMAGE_NAME"
    write_quadlet_value ContainerName "$CONTAINER_NAME"
    write_quadlet_value HostName "$HOST_ALIAS"
    write_quadlet_value Network "$NETWORK_NAME"
    write_quadlet_value UserNS keep-id
    write_quadlet_value Environment CONTAINER_HOST=unix:///run/podman/podman.sock
    write_quadlet_value Label io.wsl-dev-box.managed=true
    write_quadlet_value Label "io.wsl-dev-box.name=$CONTAINER_NAME"
    write_quadlet_value PublishPort "$SSH_PORT:22"
    for port in "${PORT_MAPPINGS[@]}"; do
        write_quadlet_value PublishPort "$port"
    done
    write_quadlet_value Volume "$VOLUME_NAME:/home"
    write_quadlet_value Volume "/run/user/$WSL_UID/podman/podman.sock:/run/podman/podman.sock"
    write_quadlet_value Volume "$SSH_PUBLIC_KEY:/run/wsl-devbox/authorized_keys.pub:ro"
    for ((mount_index=0; mount_index<${#MOUNT_SOURCES[@]}; mount_index++)); do
        mount_spec="${MOUNT_SOURCES[$mount_index]}:${MOUNT_TARGETS[$mount_index]}"
        if [[ "${MOUNT_READ_ONLY[$mount_index]}" == "true" ]]; then
            mount_spec+=":ro"
        fi
        write_quadlet_value Volume "$mount_spec"
    done
    printf '\n[Service]\nRestart=on-failure\nTimeoutStartSec=0\n\n[Install]\nWantedBy=default.target\n'
} > "$TEMP_QUADLET"
mv -f "$TEMP_QUADLET" "$QUADLET_FILE"

echo "Starting rootless Podman Quadlet unit '$SYSTEMD_UNIT'..."
systemctl --user daemon-reload
systemctl --user start "$SYSTEMD_UNIT"

echo "DevBox '$HOST_ALIAS' is ready. Connect with: ssh $HOST_ALIAS"
