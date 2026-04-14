#!/usr/bin/env bash
# startwm helpers (session lifecycle helpers for startwm.sh)

# shellcheck required scripts
. "$(dirname "${BASH_SOURCE[0]}")/hooks.sh"

prepare_xdg_runtime() {
  # Use a per-session runtime dir under /tmp so concurrent sessions (even
  # for the same UID) do not conflict. Sanitize DISPLAY into an alphanumeric
  # token so it can be used in a directory name.
  DISP_SAFE=$(printf '%s' "${DISPLAY:-}" | tr -c '[:alnum:]' '_')
  XDG_RUNTIME_DIR="/tmp/xdg-runtime-$(id -u)${DISP_SAFE:+-}$DISP_SAFE"
  mkdir -p "$XDG_RUNTIME_DIR" || true
  mkdir -p "$XDG_RUNTIME_DIR/pulse" || true
  chmod 0700 "$XDG_RUNTIME_DIR" || true
  export XDG_RUNTIME_DIR
}

maybe_start_dbus() {
  if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] && command -v dbus-launch >/dev/null 2>&1; then
    # Start dbus-launch so it is the parent of the session; it will exit with
    # the session when --exit-with-session is used. Capture the child PIDs so
    # we can clean them up on logout.
    eval "$(dbus-launch --sh-syntax --exit-with-session)" || true
  fi
}

maybe_start_keyring() {
  if command -v gnome-keyring-daemon >/dev/null 2>&1; then
    eval "$(gnome-keyring-daemon --start --components=secrets,ssh)" || true
    export SSH_AUTH_SOCK
  fi
}

maybe_start_pipewire() {
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

    if command -v pw-cli >/dev/null 2>&1; then
      for i in $(seq 1 100); do
        pw-cli info all 2>/dev/null | grep -q 'WirePlumber' && break || sleep 0.1
      done
    fi

    if command -v pactl >/dev/null 2>&1; then
      pactl info >/dev/null 2>&1 || true
      pactl load-module module-xrdp-sink 2>/dev/null || true
    fi
  fi
}

install_cleanup_trap() {
  # collect session PIDs to use during cleanup
  SESSION_PIDS="${PW_PID:-} ${WP_PID:-} ${PWP_PID:-}"

  cleanup() {
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
    # background helpers started by desktop apps do not continue running after logout.
    SESSION_UID=$(id -u)
    SELF_PID=$$
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
}


determine_singleapp_user() {
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
}

maybe_start_singleapp() {
  # If user wants a single-app session, run it instead of starting XFCE.
  # Only honor a per-user ~/.xsession when the runtime config explicitly
  # provided a `singleApp` for this user (IS_SINGLEAPP_USER==1).
  if [ "${IS_SINGLEAPP_USER:-0}" -eq 1 ] && [ -x "$HOME/.xsession" ]; then
    echo "[startwm] Starting single-app session from $HOME/.xsession" >&2
    [ -n "${DISPLAY:-}" ] && export DISPLAY
    [ -n "${XAUTHORITY:-}" ] && export XAUTHORITY
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
}

start_desktop() {
  echo "[startwm] Starting xfce4" >&2
  startxfce4 &
  XFCE_PID=$!
  wait "$XFCE_PID"
}
