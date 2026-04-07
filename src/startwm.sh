#!/usr/bin/env bash

# startxfce4 session for xrdp
if [ -r /etc/profile ]; then
  . /etc/profile
fi

RUNTIME_CONFIG="/etc/xfce-rdp/runtime_config.json"

unset DBUS_SESSION_BUS_ADDRESS

# Use a per-session runtime dir under /tmp so concurrent sessions (even
# for the same UID) do not conflict. Sanitize DISPLAY into an alphanumeric
# token so it can be used in a directory name.
DISP_SAFE=$(printf '%s' "${DISPLAY:-}" | tr -c '[:alnum:]' '_')
XDG_RUNTIME_DIR="/tmp/xdg-runtime-$(id -u)${DISP_SAFE:+-}$DISP_SAFE"
mkdir -p "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_RUNTIME_DIR/pulse"
chmod 0700 "$XDG_RUNTIME_DIR"
export XDG_RUNTIME_DIR

# Start a per-session DBus if not already running so keyring and other services can use it
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] && command -v dbus-launch >/dev/null 2>&1; then
  # Start dbus-launch so it is the parent of the session; it will exit with
  # the session when --exit-with-session is used. Capture the child PIDs so
  # we can clean them up on logout.
  eval "$(dbus-launch --sh-syntax --exit-with-session)" || true
fi

# Start gnome-keyring-daemon (provide secrets and ssh agents) so libsecret has a backend
if command -v gnome-keyring-daemon >/dev/null 2>&1; then
  # start keyring daemon with secrets and ssh components and export its env vars
  eval "$(gnome-keyring-daemon --start --components=secrets,ssh)" || true
  export SSH_AUTH_SOCK
fi

# Start PipeWire user services (pipewire, pipewire-pulse, wireplumber)
if command -v pipewire >/dev/null 2>&1; then
  : ${DISPLAY:=:10.0}
  export DISPLAY
  : ${XAUTHORITY:=$HOME/.Xauthority}
  export XAUTHORITY
  # wait briefly for X authority created by X server
  for i in $(seq 1 50); do
    [ -r "$XAUTHORITY" ] && break || sleep 0.1
  done

  # kill any stray pipewire/wireplumber instances for this user
  pkill -u "$(id -un)" pipewire 2>/dev/null || true
  pkill -u "$(id -un)" wireplumber 2>/dev/null || true
  pkill -u "$(id -un)" pipewire-pulse 2>/dev/null || true

  # start pipewire user service first and wait for its socket
  pipewire --verbose 2>"$XDG_RUNTIME_DIR/pipewire.log" &
  PW_PID=$!
  for i in $(seq 1 100); do
    [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break || sleep 0.1
  done

  # start wireplumber and pipewire-pulse after pipewire is up
  wireplumber 2>"$XDG_RUNTIME_DIR/wireplumber.log" &
  WP_PID=$!
  pipewire-pulse 2>"$XDG_RUNTIME_DIR/pipewire-pulse.log" &
  PWP_PID=$!

  # wait for the PulseAudio-compatible socket created by pipewire-pulse
  for i in $(seq 1 100); do
    [ -S "$XDG_RUNTIME_DIR/pulse/native" ] && break || sleep 0.1
  done

  # If pw-cli is available, wait until WirePlumber/PipeWire have registered
  # their globals (reduces pw-cli 'no global' transient errors seen when
  # clients probe PipeWire too early). This is a best-effort short timeout.
  if command -v pw-cli >/dev/null 2>&1; then
    for i in $(seq 1 100); do
      pw-cli info all 2>/dev/null | grep -q 'WirePlumber' && break || sleep 0.1
    done
  fi

  if command -v pactl >/dev/null 2>&1; then
    pactl info >/dev/null 2>&1 || true
    # attempt to load xrdp sink if available
    pactl load-module module-xrdp-sink 2>/dev/null || true
  fi
fi

# Track session PIDs so we can clean them up on logout
SESSION_PIDS="${PW_PID:-} ${WP_PID:-} ${PWP_PID:-}"

# Cleanup function to kill background services started for this session
cleanup()
{
  # kill in reverse order
  for pid in $SESSION_PIDS; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  sleep 0.2
  for pid in $SESSION_PIDS; do
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  done

  # As a final step, kill any remaining processes owned by this user so
  # background helpers started by desktop apps (for example the Roslyn
  # VBCSCompiler) do not continue running after logout. Exclude the
  # current shell process so the cleanup function can complete.
  SESSION_UID=$(id -u)
  SELF_PID=$$
  # list processes for the user and attempt graceful shutdown then force
  for pid in $(ps -o pid= -u "$SESSION_UID" 2>/dev/null); do
    pid=$(echo "$pid" | tr -d '[:space:]') || continue
    [ -z "$pid" ] && continue
    [ "$pid" -eq "$SELF_PID" ] && continue
    kill "$pid" 2>/dev/null || true
  done
  sleep 0.2
  for pid in $(ps -o pid= -u "$SESSION_UID" 2>/dev/null); do
    pid=$(echo "$pid" | tr -d '[:space:]') || continue
    [ -z "$pid" ] && continue
    [ "$pid" -eq "$SELF_PID" ] && continue
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  done
}

trap cleanup EXIT HUP TERM INT

# Decide whether to honor a user-provided ~/.xsession file.
# Only allow using ~/.xsession for single-app sessions when the runtime
# configuration explicitly sets `singleApp` for this username. This avoids
# accidental single-app boots when a user creates ~/.xsession manually.
# Determine current username early so hooks can be informed regardless of
# whether the runtime config file or `jq` are available.
CUR_USER=$(id -un 2>/dev/null || true)
IS_SINGLEAPP_USER=0
if [ -n "$CUR_USER" ] && [ -f "$RUNTIME_CONFIG" ] && command -v jq >/dev/null 2>&1; then
  single_app_value=$(jq -r --arg u "$CUR_USER" '.userCredentials[] | select(.username==$u) | .singleApp // empty' "$RUNTIME_CONFIG" 2>/dev/null | sed -n '1p' || true)
  if [ -n "$single_app_value" ]; then
    IS_SINGLEAPP_USER=1
  fi
fi

# entrypoint helpers are required for startwm;
HELPERS_SCRIPT="/etc/xfce-rdp/entrypoint_helpers.sh"
if [ -r "$HELPERS_SCRIPT" ]; then
  # shellcheck source=src/entrypoint_helpers.sh
  . "$HELPERS_SCRIPT"
else
  echo "[startwm] ERROR: required helper script $HELPERS_SCRIPT not found or unreadable" >&2
  exit 1
fi

# run hooks under /etc/xfce-rdp/hooks/startwm with phase 'main' if available
if command -v run_hooks >/dev/null 2>&1; then
  run_hooks "/etc/xfce-rdp/hooks/startwm" "main" "$RUNTIME_CONFIG" 0 "${CUR_USER:-}"
fi


# If user wants a single-app session, run it instead of starting XFCE.
# Only honor a per-user ~/.xsession when the runtime config explicitly
# provided a `singleApp` for this user (IS_SINGLEAPP_USER==1).
if [ "${IS_SINGLEAPP_USER:-0}" -eq 1 ] && [ -x "$HOME/.xsession" ]; then
  echo "[startwm] Starting single-app session from $HOME/.xsession" >&2
  # export existing DISPLAY/XAUTHORITY if present (do not hardcode)
  [ -n "${DISPLAY:-}" ] && export DISPLAY
  [ -n "${XAUTHORITY:-}" ] && export XAUTHORITY
  # wait briefly for X authority to be created if provided
  if [ -n "${XAUTHORITY:-}" ]; then
    for i in $(seq 1 50); do
      [ -r "$XAUTHORITY" ] && break || sleep 0.1
    done
  fi
  /bin/bash -l "$HOME/.xsession"
  exit $?
elif [ -n "${SINGLE_APP:-}" ]; then
  echo "[startwm] Starting SINGLE_APP: $SINGLE_APP" >&2
  [ -n "${DISPLAY:-}" ] && export DISPLAY
  [ -n "${XAUTHORITY:-}" ] && export XAUTHORITY
  if [ -n "${XAUTHORITY:-}" ]; then
    for i in $(seq 1 50); do
      [ -r "$XAUTHORITY" ] && break || sleep 0.1
    done
  fi
  /bin/bash -lc "$SINGLE_APP"
  exit $?
fi

# Start the desktop session and wait; when it exits the script will run cleanup
echo "[startwm] Starting xfce4" >&2
startxfce4 &
XFCE_PID=$!
wait "$XFCE_PID"
