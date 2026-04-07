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

# Create users from the validated runtime config
create_users "$runtime_config_path"

# Run hooks (if any) before starting services or executing user command
# Pass hook root then the path to the persisted runtime config so hooks can
# read or modify the JSON (hooks receive the path as their single argument).
run_entrypoint_hooks "${SKIP_ENTRYPOINT_HOOKS:-0}" "${ENTRYPOINT_STRICT:-1}" "/etc/xfce-rdp/hooks/entrypoint" "$runtime_config_path"

# If no args provided, run the default xrdp startup command
if [ $# -eq 0 ]; then
    exec /bin/bash -lc "mkdir -p /run/dbus && dbus-daemon --system --fork || true; /usr/sbin/xrdp-sesman --nodaemon & /usr/sbin/xrdp --nodaemon"
else
    exec "$@"
fi
