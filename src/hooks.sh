#!/usr/bin/env bash
## Generic hook runner (shared)
# Usage: run_hooks HOOK_NAME PHASES RUNTIME_CONFIG_PATH [EXTRA_ARGS...]
# - HOOK_NAME: name of the hook root dir under /etc/xfce-rdp/hooks (e.g. "container-start")
# - PHASES: space-separated list of phase names to process (e.g. "pre main post")
# - RUNTIME_CONFIG_PATH: path to runtime config json (may be empty)
# - EXTRA_ARGS: any extra args forwarded to hook functions

run_hooks() {
    HOOK_NAME="${1:-}"
    PHASES_STR="${2:-}"
    shift 2 || true
    EXTRA_ARGS=("$@")

    STRICT="${STRICT_HOOKS:-1}"

    if [ -z "${HOOK_NAME:-}" ]; then
        echo "[hooks] ERROR: run_hooks requires HOOK_NAME" >&2
        return 1
    fi

    HOOK_ROOT="/etc/xfce-rdp/hooks/${HOOK_NAME}"

    # source centralized runtime config path (provided in image)
    . "$(dirname "${BASH_SOURCE[0]}")/runtime_config.sh"

    # If the hook root directory doesn't exist, nothing to do
    [ -d "$HOOK_ROOT" ] || return 0

    # iterate phases
    shopt -s nullglob 2>/dev/null || true
    for phase in $PHASES_STR; do
        dir="$HOOK_ROOT/$phase"
        [ -d "$dir" ] || continue

        mapfile -t hooks < <(printf '%s\n' "$dir"/*.sh 2>/dev/null | sort -V) || true
        for hook in "${hooks[@]}"; do
            [ -n "$hook" ] || continue
            [ -f "$hook" ] || continue

            echo "[hooks] running hook $hook (phase=$phase)"

            # Export some context for hooks
            HOOK_ROOT="$HOOK_ROOT"
            HOOK_PHASE="$phase"
            HOOK_STRICT="$STRICT"
            if ! (
                export HOOK_ROOT HOOK_PHASE HOOK_STRICT
                . "$hook"
                # prefer function named hook; otherwise allow top-level script
                if declare -f hook >/dev/null 2>&1; then
                    hook "$RUNTIME_CONFIG_PATH" "${EXTRA_ARGS[@]}"
                fi
            ); then
                if [ "$STRICT" -eq 1 ]; then
                    echo "[hooks] exiting due to hook failure and STRICT=1" >&2
                    return 1
                else
                    echo "[hooks] continuing despite hook failure (STRICT!=1)" >&2
                fi
            fi
        done
    done
    shopt -u nullglob 2>/dev/null || true
}
