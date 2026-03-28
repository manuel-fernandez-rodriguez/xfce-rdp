#!/bin/sh
# Helper functions for entrypoint.sh
# - create_user: create a user, set password, configure sudo
# - validate_users_json: validate USERS_CREDENTIALS JSON

# Usage: create_user username password [sudo_flag]
# Both username and password are required. If either is missing the function
# will print an error and exit with a non-zero status.
# If sudo_flag is "true" (string) the user will be granted passwordless sudo.
create_user() {
    USER="$1"
    PASS="$2"
    SUDO_FLAG="${3:-}"

    created=0

    if [ -z "${USER:-}" ] || [ -z "${PASS:-}" ]; then
        echo "[entrypoint] ERROR: create_user requires both username and password" >&2
        echo "[entrypoint] Received username='${USER:-}' password='${PASS:+(present)}'" >&2
        exit 1
    fi
    if ! id "$USER" >/dev/null 2>&1; then
        echo "[entrypoint] Creating user '$USER'"
        if useradd -m -s /bin/bash "$USER" 2>/dev/null; then
            created=1
        else
            # if useradd failed for an unexpected reason, continue but log
            echo "[entrypoint] Warning: useradd failed for '$USER'" >&2
        fi
    fi
    if [ "$USER" != "root" ] && [ "${SUDO_FLAG:-}" = "true" ]; then
        echo "[entrypoint] Granting passwordless sudo to '$USER'"
        echo "$USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USER || true
        chmod 0440 /etc/sudoers.d/$USER || true
    fi

    # Ensure home directory ownership is correct. If /home/<user> is a
    # mounted volume it may already exist and be owned by root or another
    # UID; only change ownership when it doesn't match the user's UID to
    # avoid clobbering data/permissions unnecessarily.
    HOME_DIR="/home/$USER"
    if [ -d "$HOME_DIR" ]; then
        owner_uid=$(stat -c '%u' "$HOME_DIR" 2>/dev/null || true)
        user_uid=$(id -u "$USER" 2>/dev/null || true)
        if [ -z "$owner_uid" ] || [ "$owner_uid" != "$user_uid" ]; then
            echo "[entrypoint] Setting ownership of $HOME_DIR to $USER:$USER"
            chown -R "$USER":"$USER" "$HOME_DIR" 2>/dev/null || true
        else
            echo "[entrypoint] Home directory $HOME_DIR already owned by user (uid=$user_uid); skipping chown"
        fi
    else
        mkdir -p "$HOME_DIR" 2>/dev/null || true
        chown -R "$USER":"$USER" "$HOME_DIR" 2>/dev/null || true
    fi

    # Set password only when the user was created by this entrypoint.
    # This avoids overwriting passwords changed by users in a persisted home volume.
    if [ "$created" -eq 1 ]; then
        if echo "$USER:$PASS" | chpasswd 2>/dev/null; then
            :
        else
            echo "[entrypoint] Failed to set password for user '$USER'" >&2
        fi
    else
        echo "[entrypoint] User '$USER' already exists; leaving password unchanged" >&2
    fi
}

# Ensure any Chromium/Electron "chrome-sandbox" helper is owned by root and
# has the setuid bit set so the native sandbox helper can run without
# requiring an unconfined seccomp profile. This is more secure than
# disabling seccomp and allows the sandbox to work inside Docker's default
# profile.
disable_electron_sandbox() {
    # Look for common chrome-sandbox helpers (some packages or builds may
    # have slight name differences). Resolve symlinks, print diagnostics to
    # the container logs and make the resolved file owned by root with the
    # setuid bit so Chromium/Electron can create namespaces under Docker's
    # default seccomp profile.
    FOUND=0
    for f in $(find / -path /proc -prune -o \( -name chrome-sandbox \) -print 2>/dev/null); do
        FOUND=1
    # resolve symlink if present
    if [ -L "$f" ]; then
        target=$(readlink -f "$f" 2>/dev/null) || target="$f"
    else
        target="$f"
    fi
    echo "[entrypoint] Found sandbox helper: $f -> $target" >&2
    # show file type and permissions for debugging
    file "$target" 2>/dev/null | sed 's/^/  /' >&2 || true
    ls -l "$target" 2>/dev/null | sed 's/^/  /' >&2 || true

    # try to make it owned by root and set the setuid bit
    chown root:root "$target" 2>/dev/null || true
    chmod a+x "$target" 2>/dev/null || true
    chmod 4755 "$target" 2>/dev/null || true
    ls -l "$target" 2>/dev/null | sed 's/^/  /' >&2 || true
    done
    if [ "$FOUND" -eq 0 ]; then
        echo "[entrypoint] No chrome-sandbox helper found on filesystem" >&2
    fi

    # As a fallback, export an environment variable. Some Electron builds
    # also respect ELECTRON_DISABLE_SANDBOX.
    export ELECTRON_DISABLE_SANDBOX=1
}

# Load USERS_CREDENTIALS from a secret file or environment and validate.
# Supports USERS_CREDENTIALS provided either as a
# file at /run/secrets/users_credentials (recommended for Docker secrets or
# Kubernetes Secrets mounted as files) or via the environment variable
# USERS_CREDENTIALS. The content must be a JSON array of objects with fields
# `username`, `password` and `sudo` (boolean).
# On success prints the JSON to stdout. Returns non-zero on failure.

load_users_json() {
    out_path="${1:-/tmp/users_credentials.json.$$}"

    # Prefer secret file when present
    if [ -f /run/secrets/users_credentials ]; then
        echo "[entrypoint] Loading USERS_CREDENTIALS from /run/secrets/users_credentials" >&2
        json=$(cat /run/secrets/users_credentials 2>/dev/null || true)
    elif [ -n "${USERS_CREDENTIALS:-}" ]; then
        echo "[entrypoint] Loading USERS_CREDENTIALS from environment" >&2
        json="$USERS_CREDENTIALS"
    else
        echo "[entrypoint] ERROR: USERS_CREDENTIALS not provided. Provide a JSON array via /run/secrets/users_credentials or the USERS_CREDENTIALS environment variable." >&2
        return 1
    fi

    # validate (this will exit on failure)
    validate_users_json "$json"

    # write validated json to requested path
    printf '%s' "$json" > "$out_path"
}


# Validate the USERS_CREDENTIALS JSON input.
# This performs a quick syntax check with `jq` and ensures every entry has
# non-empty `username` and `password` fields. Exits with non-zero status on
# any validation failure.
validate_users_json() {
    json="${1:-}"
    if [ -z "${json:-}" ]; then
        echo "[entrypoint] ERROR: USERS_CREDENTIALS is empty" >&2
        exit 1
    fi

    # Quick JSON syntax validation
    echo "$json" | jq empty >/dev/null 2>&1 || {
        echo "[entrypoint] ERROR: USERS_CREDENTIALS contains invalid JSON" >&2
        exit 1
    }

    # Ensure every entry contains both username and password (non-empty)
    missing_count=$(echo "$json" | jq 'map(select((.username//"" )=="" or (.password//"" )=="")) | length' 2>/dev/null || echo 0)
    if [ "${missing_count:-0}" -gt 0 ]; then
        echo "[entrypoint] ERROR: USERS_CREDENTIALS contains ${missing_count} entry(ies) missing username or password" >&2
        echo "[entrypoint] Offending entries:" >&2
        echo "$json" | jq 'map(select((.username//"" )=="" or (.password//"" )==""))' >&2 || true
        exit 1
    fi
}
