#!/bin/sh

# startxfce4 session for xrdp
if [ -r /etc/profile ]; then
  . /etc/profile
fi

unset DBUS_SESSION_BUS_ADDRESS

# Use a per-user runtime dir under /tmp so non-root sessions can create it
XDG_RUNTIME_DIR=/tmp/xdg-runtime-$(id -u)
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
  pipewire --verbose 2>/tmp/pipewire.log &
  PW_PID=$!
  for i in $(seq 1 100); do
    [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break || sleep 0.1
  done

  # start wireplumber and pipewire-pulse after pipewire is up
  wireplumber 2>/tmp/wireplumber.log &
  WP_PID=$!
  pipewire-pulse 2>/tmp/pipewire-pulse.log &
  PWP_PID=$!

  # wait for the PulseAudio-compatible socket created by pipewire-pulse
  for i in $(seq 1 100); do
    [ -S "$XDG_RUNTIME_DIR/pulse/native" ] && break || sleep 0.1
  done

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

# Start the desktop session and wait; when it exits the script will run cleanup
startxfce4 &
XFCE_PID=$!
wait "$XFCE_PID"
