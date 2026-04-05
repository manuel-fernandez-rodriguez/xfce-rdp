#!/usr/bin/env bash
set -euo pipefail

# Usage: ./run.sh [--image IMAGE] [--container NAME] [--host-port PORT] [--shm-size SIZE] [--home-bind HOST_PATH]
# Defaults: image=local/xfce-rdp:latest, container=xfce-rdp, host_port=33890, shm_size=1g
# If --home-bind is provided the host path will be mounted at /home. Otherwise a
# deterministic named docker volume "${container}-home" will be created and mounted
# at /home so user homes persist across container recreation.

# Defaults
image="local/xfce-rdp:latest"
container="xfce-rdp"
host_port="33890"
shm_size="1g"
home_bind=""
home_volume=""
home_volume_specified=0

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  --image IMAGE         Docker image to run (default: ${image})
  --container NAME      Container name (default: ${container})
  --host-port PORT      Host port to publish to 3389 (default: ${host_port})
  --shm-size SIZE       Size passed to --shm-size (default: ${shm_size})
  --home-bind PATH       Host path to bind-mount at /home (optional)
  --home-volume NAME     Name of the docker volume to mount at /home. If the
                         option is provided without a NAME it defaults to
                         "${container}-home". (optional)
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
    --home-bind=*) home_bind="${1#*=}"; shift;;
    --home-bind) home_bind="$2"; shift 2;;
    --home-volume=*) home_volume="${1#*=}"; shift;;
    --home-volume) home_volume="$2"; home_volume_specified=1; shift 2;;
    -h|--help) show_help; exit 0;;
    *) echo "Unknown option: $1" >&2; show_help; exit 1;;
  esac
done

# Default users JSON (used only if ./users.json is not present)
default_users='[{"username":"developer","password":"s3cr3t","sudo":true}, {"username":"developer2","password":"s3cr3t", "singleApp": "/usr/bin/xfce4-terminal" }, {"username":"developer3","password":"s3cr3t", "singleApp": "/usr/bin/xfce4-terminal" }]'

# Build docker run arguments conditionally
docker_args=()

# If a local users.json exists, mount it as a read-only secret file. Otherwise pass the
# USERS_CREDENTIALS environment variable.
if [ -f ./users.json ]; then
  docker_args+=( -v "$(pwd)/users.json:/run/secrets/users_credentials:ro" )
else
  docker_args+=( -e "USERS_CREDENTIALS=${default_users}" )
fi

# If a host path was provided, bind-mount it at /home.
if [ -n "${home_bind}" ]; then
  # Ensure host path exists
  mkdir -p "${home_bind}"
  docker_args+=( -v "${home_bind}:/home" )
fi

# Only create and mount a named volume when --home-volume was explicitly provided
if [ "${home_volume_specified}" -eq 1 ]; then
  # determine volume name: provided via --home-volume or default to ${container}-home
  if [ -z "${home_volume}" ]; then
    home_volume="${container}-home"
  fi
  docker volume create "${home_volume}" >/dev/null || true
  docker_args+=( -v "${home_volume}:/home" )
fi

docker run "${docker_args[@]}" \
  -p "${host_port}:3389" --shm-size=${shm_size} -d -it --name "${container}" "${image}"
