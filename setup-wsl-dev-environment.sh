#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage:
  setup-wsl-dev-environment.sh --username <linux-user> --box <blueprint-folder> [--instance <name>] [--yes] [--update] [--remove]

Options:
  -u, --username  User to create/use inside the DevBox container.
  -b, --box       Box to build. Omit it only when creating the common core box.
  -i, --instance  Optional named container instance using the selected box image.
  -y, --yes       Replace an existing image/container without prompting.
      --update    Recreate an existing box container without rebuilding its image.
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

if [[ -n "$INSTANCE" ]] && ! [[ "$INSTANCE" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; then
    echo "ERROR: Instance must start with a lowercase letter or number and contain only lowercase letters, numbers, '.', '_' or '-'."
    exit 1
fi

if [[ -n "$INSTANCE" && -z "$BOX" ]]; then
    echo "ERROR: --instance requires --box."
    exit 1
fi

if [[ -n "$BOX" ]] && ! [[ "$BOX" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    echo "ERROR: --box must exactly match a lowercase blueprint folder name and contain only letters, numbers, '-' or '_'. The spelling and separator character are preserved."
    exit 1
fi

if [[ "$BOX" == "core_box" ]]; then
    echo "ERROR: core_box is reserved for the shared foundation image. Select another blueprint folder."
    exit 1
fi

if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "ERROR: Username must be a valid Linux username."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker CE CLI is not installed in the default Ubuntu WSL distribution."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "Starting the Docker CE daemon in WSL..."
    sudo service docker start
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker CE is not running or the user is not in the docker group."
    echo "Run: sudo service docker start"
    echo "Then start a new Ubuntu session and try again."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

ROOT_MOUNT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="core_box"
CORE_CONFIG_FILE_PATH="core_box/config.json"
CONFIG_FILE_PATH="core_box/config.json"

if [[ -n "$BOX" ]]; then
    BUILD_DIR="$BOX"
    CONFIG_FILE_PATH="$BOX/config.json"
fi

if [[ ! -d "$SCRIPT_DIR/$BUILD_DIR" ]]; then
    echo "ERROR: Box directory does not exist: $SCRIPT_DIR/$BUILD_DIR"
    exit 1
fi

CONFIG_FILES=("$SCRIPT_DIR/$CONFIG_FILE_PATH")
MOUNT_CONFIG_FILES=("$SCRIPT_DIR/$CORE_CONFIG_FILE_PATH")
if [[ -n "$BOX" ]]; then
    MOUNT_CONFIG_FILES+=("$SCRIPT_DIR/$BOX/config.json")
    if [[ -n "$INSTANCE" ]]; then
        INSTANCE_CONFIG_FILE_PATH="$BUILD_DIR/instances/$INSTANCE/config.json"
        CONFIG_FILE_PATH="$INSTANCE_CONFIG_FILE_PATH"
        if [[ ! -f "$SCRIPT_DIR/$CONFIG_FILE_PATH" ]]; then
            if [[ "$REMOVE_ONLY" -eq 1 ]]; then
                CONFIG_FILE_PATH="$CORE_CONFIG_FILE_PATH"
                CONFIG_FILES=("$SCRIPT_DIR/$CORE_CONFIG_FILE_PATH")
            else
                echo "ERROR: Instance port configuration not found: $SCRIPT_DIR/$CONFIG_FILE_PATH"
                echo "Create it from the box config.json before using this instance."
                exit 1
            fi
        else
            CONFIG_FILES=("$SCRIPT_DIR/$CORE_CONFIG_FILE_PATH" "$SCRIPT_DIR/$CONFIG_FILE_PATH")
            MOUNT_CONFIG_FILES+=("$SCRIPT_DIR/$CONFIG_FILE_PATH")
        fi
    else
        CONFIG_FILES=("$SCRIPT_DIR/$CORE_CONFIG_FILE_PATH" "$SCRIPT_DIR/$CONFIG_FILE_PATH")
    fi
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required to read port configuration."; exit 1; }
for config_file in "${CONFIG_FILES[@]}"; do
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Port configuration not found: $config_file"
        exit 1
    fi
    jq empty "$config_file"
done

for config_file in "${MOUNT_CONFIG_FILES[@]}"; do
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Mount configuration not found: $config_file"
        exit 1
    fi
    jq empty "$config_file"
done

SSH_PORT="$(jq -r '.ssh_port // empty' "$SCRIPT_DIR/$CONFIG_FILE_PATH")"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    echo "ERROR: $CONFIG_FILE_PATH must define ssh_port between 1 and 65535."
    exit 1
fi

if [[ -z "$BOX" ]]; then
    CONTAINER_NAME="core_box"
    IMAGE_NAME="core_box:latest"
    HOST_ALIAS="core_box"
elif [[ -n "$INSTANCE" ]]; then
    CONTAINER_NAME="$BOX-$INSTANCE"
    IMAGE_NAME="$BOX:latest"
    HOST_ALIAS="$BOX-$INSTANCE"
else
    CONTAINER_NAME="$BOX"
    IMAGE_NAME="$BOX:latest"
    HOST_ALIAS="$BOX"
fi

if [[ "$REMOVE_ONLY" -eq 1 ]]; then
    containers_to_remove=()
    while IFS= read -r existing_container; do
        if [[ "$existing_container" == "$CONTAINER_NAME" ]]; then
            containers_to_remove+=("$existing_container")
        elif [[ -z "$INSTANCE" && "$existing_container" == "$BOX-"* ]]; then
            containers_to_remove+=("$existing_container")
        fi
    done < <(docker ps -a --format '{{.Names}}')

    image_exists=0
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        image_exists=1
    fi

    if [[ "${#containers_to_remove[@]}" -eq 0 && "$image_exists" -eq 0 ]]; then
        echo "No removable resources found for box '$BOX'."
        exit 0
    fi

    echo
    if [[ -n "$INSTANCE" ]]; then
        echo "WARNING: This will remove instance container '$CONTAINER_NAME'."
        echo "The shared image and persistent volume will be retained."
    else
        echo "WARNING: This will remove box image '$IMAGE_NAME' and all containers/instances for '$BOX'."
        echo "The shared core image and persistent volume will be retained."
    fi

    if [[ "$AUTO_CONFIRM" -eq 0 ]]; then
        read -r -p "Continue with removal? [y/N] " answer
        case "$answer" in
            y|Y|yes|YES|Yes) ;;
            *)
                echo "Removal cancelled. Existing resources were not changed."
                exit 2
                ;;
        esac
    fi

    for container_to_remove in "${containers_to_remove[@]}"; do
        echo "Removing container '$container_to_remove'..."
        docker rm --force "$container_to_remove"
    done

    if [[ -z "$INSTANCE" && "$image_exists" -eq 1 ]]; then
        echo "Removing image '$IMAGE_NAME'..."
        docker image rm "$IMAGE_NAME"
    fi

    echo "Removal completed."
    exit 0
fi

# Configure SSH in the Ubuntu WSL user's home. The PowerShell wrapper performs
# the matching configuration in the Windows user's home.
cp "$SCRIPT_DIR/core_box/keys/wsl-dev-container-key" "$SSH_DIR/"
cp "$SCRIPT_DIR/core_box/keys/wsl-dev-container-key.pub" "$SSH_DIR/"
chmod 600 "$SSH_DIR/wsl-dev-container-key"

SSH_CONFIG="$SSH_DIR/config"
touch "$SSH_CONFIG"
if ! grep -qE "^Host[[:space:]]+$HOST_ALIAS([[:space:]]|$)" "$SSH_CONFIG"; then
    cat >> "$SSH_CONFIG" <<EOF

Host $HOST_ALIAS
    HostName localhost
    User $USERNAME
    Port $SSH_PORT
    IdentityFile $SSH_DIR/wsl-dev-container-key
    IdentitiesOnly yes
EOF
    echo "Added Ubuntu SSH host '$HOST_ALIAS'."
fi

ssh-keygen -f "$SSH_DIR/known_hosts" -R "[localhost]:$SSH_PORT" 2>/dev/null || true

build_image() {
    local image_directory="$1"
    local image_name="$2"

    echo "Building image '$image_name'..."
    pushd "$SCRIPT_DIR/$image_directory" >/dev/null
    docker build --progress=plain \
        --build-arg USERNAME="$USERNAME" \
        -t "$image_name" \
        -f "$SCRIPT_DIR/$image_directory/Dockerfile" .
    popd >/dev/null
}

IMAGE_EXISTS=0
CONTAINER_EXISTS=0
if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    IMAGE_EXISTS=1
fi
if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    CONTAINER_EXISTS=1
fi

if [[ "$UPDATE_ONLY" -eq 1 ]]; then
    if [[ "$IMAGE_EXISTS" -eq 0 ]]; then
        echo "ERROR: Box image '$IMAGE_NAME' does not exist. Run Box mode first."
        exit 1
    fi
    if [[ "$CONTAINER_EXISTS" -eq 1 ]]; then
        echo "Recreating existing box container '$CONTAINER_NAME' from the current configuration..."
        docker rm --force "$CONTAINER_NAME"
    else
        echo "Creating missing box container '$CONTAINER_NAME' from the existing image..."
    fi
else
    if [[ -n "$BOX" ]] && ! docker image inspect "core_box:latest" >/dev/null 2>&1; then
        echo "The core image is missing. Building core_box:latest before the box image..."
        build_image "core_box" "core_box:latest"
    fi

    if [[ -n "$INSTANCE" ]]; then
        if [[ "$IMAGE_EXISTS" -eq 0 ]]; then
            build_image "$BUILD_DIR" "$IMAGE_NAME"
            IMAGE_EXISTS=1
        fi

        if [[ "$CONTAINER_EXISTS" -eq 1 ]]; then
            echo
            echo "WARNING: Existing box instance '$HOST_ALIAS' was found."
            echo "Replacing it will remove only the instance container; the shared image and volume are retained."

            if [[ "$AUTO_CONFIRM" -eq 0 ]]; then
                read -r -p "Continue and replace this instance? [y/N] " answer
                case "$answer" in
                    y|Y|yes|YES|Yes) ;;
                    *)
                        echo "Instance replacement cancelled. Existing resources were not changed."
                        exit 2
                        ;;
                esac
            fi

            docker rm --force "$CONTAINER_NAME"
        fi
    elif [[ "$IMAGE_EXISTS" -eq 1 || "$CONTAINER_EXISTS" -eq 1 ]]; then
        echo
        echo "WARNING: Existing DevBox resources were found for '$HOST_ALIAS'."
        [[ "$IMAGE_EXISTS" -eq 1 ]] && echo "  Image:     $IMAGE_NAME"
        [[ "$CONTAINER_EXISTS" -eq 1 ]] && echo "  Container: $CONTAINER_NAME"
        echo "Replacing them will remove the container and rebuild the image."

        if [[ "$AUTO_CONFIRM" -eq 0 ]]; then
            read -r -p "Continue and replace these resources? [y/N] " answer
            case "$answer" in
                y|Y|yes|YES|Yes) ;;
                *)
                    echo "Replacement cancelled. Existing resources were not changed."
                    exit 2
                    ;;
            esac
        fi

        if [[ "$CONTAINER_EXISTS" -eq 1 ]]; then
            docker rm --force "$CONTAINER_NAME"
        fi
        if [[ "$IMAGE_EXISTS" -eq 1 ]]; then
            docker image rm "$IMAGE_NAME"
        fi
    fi

    if [[ -z "$INSTANCE" ]]; then
        build_image "$BUILD_DIR" "$IMAGE_NAME"
    fi
fi

VOLUME_NAME="wsl_dev_home"
NETWORK_NAME="wsl-network"
CONTAINER_MOUNT_PATH="/wsl/shared"

docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME" >/dev/null
docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || docker volume create "$VOLUME_NAME" >/dev/null

PORT_ARGS=()
MOUNT_ARGS=()
validate_port_number() {
    local port_number="$1"
    if (( port_number < 1 || port_number > 65535 )); then
        echo "ERROR: Port must be between 1 and 65535: $port_number"
        exit 1
    fi
}

add_port_mapping() {
    local spec="$1"
    local host_start host_end container_start container_end

    if [[ "$spec" =~ ^([0-9]+):([0-9]+)$ ]]; then
        validate_port_number "${BASH_REMATCH[1]}"
        validate_port_number "${BASH_REMATCH[2]}"
        PORT_ARGS+=("-p" "$spec")
        return 0
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

        if (( host_start > host_end || container_start > container_end )); then
            echo "ERROR: Invalid port range: $spec"
            exit 1
        fi
        if (( host_end - host_start != container_end - container_start )); then
            echo "ERROR: Host and container ranges must have the same size: $spec"
            exit 1
        fi

        PORT_ARGS+=("-p" "$host_start-$host_end:$container_start-$container_end")
        return 0
    fi

    if [[ "$spec" =~ ^[0-9]+$ ]]; then
        validate_port_number "$spec"
        PORT_ARGS+=("-p" "$spec:$spec")
        return 0
    fi

    echo "ERROR: Invalid port mapping '$spec'. Use HOST:CONTAINER, HOST-RANGE, or HOST-RANGE:CONTAINER-RANGE."
    exit 1
}

for config_file in "${CONFIG_FILES[@]}"; do
    while IFS= read -r port; do
        add_port_mapping "$port"
    done < <(jq -r '.ports[]? // empty' "$config_file")
done

add_bind_mount() {
    local source_path="$1"
    local target_path="$2"
    local read_only="$3"
    local mount_spec

    if [[ -z "$source_path" || -z "$target_path" ]]; then
        echo "ERROR: Each mount must define non-empty source and target paths."
        exit 1
    fi
    if [[ "$source_path" != /* || "$target_path" != /* ]]; then
        echo "ERROR: Mount source and target must be absolute Linux paths: $source_path -> $target_path"
        echo "Use paths such as /mnt/c/project or /wsl/shared/project."
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

    mount_spec="type=bind,source=$source_path,target=$target_path"
    if [[ "$read_only" == "true" ]]; then
        mount_spec+=",readonly"
    fi
    MOUNT_ARGS+=("--mount" "$mount_spec")
    if [[ "$read_only" == "true" ]]; then
        echo "Bind mount (read-only): $source_path -> $target_path"
    else
        echo "Bind mount: $source_path -> $target_path"
    fi
}

for config_file in "${MOUNT_CONFIG_FILES[@]}"; do
    mount_records="$(jq -r '.mounts[]? | [.source // empty, .target // empty, (.read_only // false)] | @tsv' "$config_file")"
    if [[ -n "$mount_records" ]]; then
        while IFS=$'\t' read -r source_path target_path read_only; do
            add_bind_mount "$source_path" "$target_path" "$read_only"
        done <<< "$mount_records"
    fi
done

if (( ${#PORT_ARGS[@]} > 0 )); then
    echo "Additional port mappings: ${PORT_ARGS[*]}"
fi

echo "Starting container '$CONTAINER_NAME' with automatic restart enabled..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network "$NETWORK_NAME" \
    --hostname "$HOST_ALIAS" \
    -p "${SSH_PORT}:22" \
    "${PORT_ARGS[@]}" \
    "${MOUNT_ARGS[@]}" \
    --add-host "host.docker.internal:host-gateway" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${ROOT_MOUNT}:${CONTAINER_MOUNT_PATH}" \
    -v "${VOLUME_NAME}:/home" \
    "$IMAGE_NAME"

echo "DevBox '$HOST_ALIAS' is ready. Connect with: ssh $HOST_ALIAS"
