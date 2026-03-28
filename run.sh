#!/usr/bin/env bash
set -euo pipefail

# Usage: ./run.sh [--image IMAGE] [--container NAME] [--host-port PORT] [--shm-size SIZE] [--home-volume VOLUME]
# Defaults: image=local/dev-box:latest, container=dev-box, host_port=33890, shm_size=1g
# If --home-volume is provided, a docker volume with that name will be created (if needed)
# and mounted at /home in the container. If a local ./users.json file exists it will be
# bind-mounted into /run/secrets/users_credentials:ro. Otherwise the script will pass a
# default USERS_CREDENTIALS environment variable into the container.

# Defaults
image="local/dev-box:latest"
container="dev-box"
host_port="33890"
shm_size="1g"
volume_name=""

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  --image IMAGE         Docker image to run (default: ${image})
  --container NAME      Container name (default: ${container})
  --host-port PORT      Host port to publish to 3389 (default: ${host_port})
  --shm-size SIZE       Size passed to --shm-size (default: ${shm_size})
  --home-volume VOLUME  Name of docker volume to create and mount at /home (optional)
  -h, --help            Show this help and exit
EOF
}

# Parse named parameters
while [ "$#" -gt 0 ]; do
  case "$1" in
    --image=*) image="${1#*=}"; shift;;
    --image) image="$2"; shift 2;;
    --container=*) container="${1#*=}"; shift;;
    --container) container="$2"; shift 2;;
    --host-port=*) host_port="${1#*=}"; shift;;
    --host-port) host_port="$2"; shift 2;;
    --shm-size=*) shm_size="${1#*=}"; shift;;
    --shm-size) shm_size="$2"; shift 2;;
    --home-volume=*) volume_name="${1#*=}"; shift;;
    --home-volume) volume_name="$2"; shift 2;;
    -h|--help) show_help; exit 0;;
    *) echo "Unknown option: $1" >&2; show_help; exit 1;;
  esac
done

# Default users JSON (used only if ./users.json is not present)
default_users='[{"username":"developer","password":"s3cr3t","sudo":true}, {"username":"developer2","password":"s3cr3t"}]'

# Build docker run arguments conditionally
docker_args=()

# If a local users.json exists, mount it as a read-only secret file. Otherwise pass the
# USERS_CREDENTIALS environment variable.
if [ -f ./users.json ]; then
  docker_args+=( -v "$(pwd)/users.json:/run/secrets/users_credentials:ro" )
else
  docker_args+=( -e "USERS_CREDENTIALS=${default_users}" )
fi

# If a volume name was provided, create it (idempotent) and mount it at /home
if [ -n "${volume_name}" ]; then
  docker volume create "${volume_name}" >/dev/null || true
  docker_args+=( -v "${volume_name}:/home" )
fi

docker run "${docker_args[@]}" \
  -p "${host_port}:3389" --shm-size=${shm_size} -d --name "${container}" "${image}"
