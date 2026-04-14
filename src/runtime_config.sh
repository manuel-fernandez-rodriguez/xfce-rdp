#!/usr/bin/env bash
# Centralized runtime config file path for scripts
# Allows overriding via environment when needed.
: "${RUNTIME_CONFIG_PATH:=/etc/xfce-rdp/runtime_config.json}"
export RUNTIME_CONFIG_PATH


# Load RUNTIME_CONFIG content from a secret file or environment and validate.
# On success the validated JSON is written to "$RUNTIME_CONFIG_PATH" and the
# path is printed to stdout. Returns non-zero on failure.
load_runtime_config() {
    # Prefer secret file when present
    if [ -f /run/secrets/runtime_config ]; then
        echo "[entrypoint] Loading RUNTIME_CONFIG from /run/secrets/runtime_config" >&2
        json=$(cat /run/secrets/runtime_config 2>/dev/null || true)
    elif [ -n "${RUNTIME_CONFIG:-}" ]; then
        echo "[entrypoint] Loading RUNTIME_CONFIG from environment" >&2
        json="$RUNTIME_CONFIG"
    else
        echo "[entrypoint] ERROR: RUNTIME_CONFIG not provided. Provide a JSON object via /run/secrets/runtime_config or the RUNTIME_CONFIG environment variable." >&2
        return 1
    fi

    # validate (this will exit on failure)
    validate_runtime_config "$json"

    # write validated json to requested path
    mkdir -p "$(dirname "$RUNTIME_CONFIG_PATH")" 2>/dev/null || true
    printf '%s' "$json" > "$RUNTIME_CONFIG_PATH" 2>/dev/null || true
    echo "$RUNTIME_CONFIG_PATH"
}


# Validate the RUNTIME_CONFIG JSON input.
# This performs a quick syntax check with `jq` and ensures `.userCredentials`
# exists and is an array. It also checks each entry in that array has non-empty
# `username` and `password` fields. Exits with non-zero status on any
# validation failure.
validate_runtime_config() {
    json="${1:-}"
    if [ -z "${json:-}" ]; then
        echo "[entrypoint] ERROR: RUNTIME_CONFIG is empty" >&2
        exit 1
    fi

    # Quick JSON syntax validation
    echo "$json" | jq empty >/dev/null 2>&1 || {
        echo "[entrypoint] ERROR: RUNTIME_CONFIG contains invalid JSON" >&2
        exit 1
    }

    # Ensure .userCredentials exists and is an array
    is_array=$(echo "$json" | jq 'has("userCredentials") and (.userCredentials | type == "array")' 2>/dev/null || echo false)
    if [ "$is_array" != "true" ]; then
        echo "[entrypoint] ERROR: RUNTIME_CONFIG must contain a top-level \"userCredentials\" array" >&2
        exit 1
    fi

    # Ensure every entry contains both username and password (non-empty)
    missing_count=$(echo "$json" | jq '.userCredentials | map(select((.username//"" )=="" or (.password//"" )=="")) | length' 2>/dev/null || echo 0)
    if [ "${missing_count:-0}" -gt 0 ]; then
        echo "[entrypoint] ERROR: RUNTIME_CONFIG.userCredentials contains ${missing_count} entry(ies) missing username or password" >&2
        echo "[entrypoint] Offending entries:" >&2
        echo "$json" | jq '.userCredentials | map(select((.username//"" )=="" or (.password//"" )==""))' >&2 || true
        exit 1
    fi
}
