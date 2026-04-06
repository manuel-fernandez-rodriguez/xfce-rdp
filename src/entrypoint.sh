#!/usr/bin/env bash
set -e

# Entrypoint
# RUNTIME_CONFIG must be provided either
# via /run/secrets/runtime_config or the
# RUNTIME_CONFIG environment variable (JSON object).


# shellcheck source=src/entrypoint_helpers.sh
. "$(dirname "$0")/entrypoint_helpers.sh"

# Load runtime configuration and persist to a known path. The function prints
# the path to the validated runtime config file on success.
runtime_config_path="$(load_runtime_config)" || exit 1

# Read user credentials from the runtime config file and create users.
mapfile -t users_credentials < <(jq -c '.userCredentials[]' "$runtime_config_path" 2>/dev/null || true)

for u in "${users_credentials[@]}"; do
    [ -n "$u" ] || continue
    uname=$(jq -r '.username // empty' <<<"$u")
    upw=$(jq -r '.password // empty' <<<"$u")
    usudo=$(jq -r '.sudo // false' <<<"$u")
    singleApp=$(jq -r '.singleApp // empty' <<<"$u")
    create_user "$uname" "$upw" "$usudo" "$singleApp"
done

# Run hooks (if any) before starting services or executing user command
# Pass hook root then the path to the persisted runtime config so hooks can
# read or modify the JSON (hooks receive the path as their single argument).
run_entrypoint_hooks "${SKIP_ENTRYPOINT_HOOKS:-0}" "${ENTRYPOINT_STRICT:-1}" "/etc/entrypoint.d" "$runtime_config_path"

# If no args provided, run the default xrdp startup command
if [ $# -eq 0 ]; then
    exec /bin/bash -lc "mkdir -p /run/dbus && dbus-daemon --system --fork || true; /usr/sbin/xrdp-sesman --nodaemon & /usr/sbin/xrdp --nodaemon"
else
    exec "$@"
fi
