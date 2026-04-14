#!/usr/bin/env bash

# startxfce4 session for xrdp
if [ -r /etc/profile ]; then
  . /etc/profile
fi

RUNTIME_CONFIG="/etc/xfce-rdp/runtime_config.json"

# Source helpers: prefer /etc/xfce-rdp/startwm_helpers.sh, fall back to script dir
STARTWM_HELPERS="/etc/xfce-rdp/startwm_helpers.sh"
if [ -r "$STARTWM_HELPERS" ]; then
  # shellcheck source=src/startwm_helpers.sh
  . "$STARTWM_HELPERS"
else
  echo "[startwm] ERROR: required helper script $STARTWM_HELPERS not found or unreadable" >&2
  exit 1
fi

# Prepare per-session runtime dir
prepare_xdg_runtime

# Start session services if available.
maybe_start_dbus
maybe_start_keyring
maybe_start_pipewire

install_cleanup_trap

determine_singleapp_user

# entrypoint helpers are required for startwm;
HELPERS_SCRIPT="/etc/xfce-rdp/entrypoint_helpers.sh"
if [ -r "$HELPERS_SCRIPT" ]; then
  # shellcheck source=src/entrypoint_helpers.sh
  . "$HELPERS_SCRIPT"
else
  echo "[startwm] ERROR: required helper script $HELPERS_SCRIPT not found or unreadable" >&2
  exit 1
fi

# Run hooks under /etc/xfce-rdp/hooks/startwm with phase 'main'.
# Call run_hooks directly (hooks.sh provides it) and pass runtime config and
# current user as extra arg.
if command -v run_hooks >/dev/null 2>&1; then
  run_hooks "user-login" "main" "${CUR_USER:-}"
fi

# If user wants a single-app session, run it instead of starting XFCE.
# Only honor a per-user ~/.xsession when the runtime config explicitly
# provided a `singleApp` for this user (IS_SINGLEAPP_USER==1).
maybe_start_singleapp

start_desktop
