#!/usr/bin/env bash
set -e

# Entrypoint
# USERS_CREDENTIALS must be provided either
# via /run/secrets/users_credentials or the
# USERS_CREDENTIALS environment variable (JSON array).


# shellcheck source=src/entrypoint_helpers.sh
. "$(dirname "$0")/entrypoint_helpers.sh"

users_json="$(load_users_json)" || exit 1

mapfile -t users_credentials < <(jq -c '.[]' <<<"$users_json" 2>/dev/null || true)

for u in "${users_credentials[@]}"; do
    [ -n "$u" ] || continue
    uname=$(jq -r '.username // empty' <<<"$u")
    upw=$(jq -r '.password // empty' <<<"$u")
    usudo=$(jq -r '.sudo // false' <<<"$u")
    singleApp=$(jq -r '.singleApp // empty' <<<"$u")
    create_user "$uname" "$upw" "$usudo" "$singleApp"
done

# Run hooks (if any) before starting services or executing user command
# Pass hook root then the name of the users_credentials array so the
# function can create a nameref to iterate the array by reference.
run_entrypoint_hooks "${SKIP_ENTRYPOINT_HOOKS:-0}" "${ENTRYPOINT_STRICT:-1}" "/etc/entrypoint.d" users_credentials

# If no args provided, run the default xrdp startup command
if [ $# -eq 0 ]; then
    exec /bin/bash -lc "mkdir -p /run/dbus && dbus-daemon --system --fork || true; /usr/sbin/xrdp-sesman --nodaemon & /usr/sbin/xrdp --nodaemon"
else
    exec "$@"
fi
