#!/usr/bin/env bash
# Helper functions for entrypoint.sh
# - create_user: create a user, set password, configure sudo
# - validate_users_json: validate USERS_CREDENTIALS JSON

# Usage: create_user username password [sudo_flag] [singleapp]
# Both username and password are required. If either is missing the function
# will print an error and exit with a non-zero status.
# If sudo_flag is "true" (string) the user will be granted passwordless sudo.
# If singleapp is provided, a per-user ~/.xsession wrapper will be created
# containing the provided command line so a single-application session can run.
create_user() {
    USER="$1"
    PASS="$2"
    SUDO_FLAG="${3:-}"
    SINGLEAPP="${4:-}"

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

    # Create per-user ~/.xsession when SINGLEAPP is provided.
    # The wrapper will start a minimal window manager (if available), launch
    # the requested single application, attempt to maximize its window using
    # wmctrl (if installed) and wait for the app to exit so the session
    # terminates cleanly.
    if [ -n "${SINGLEAPP:-}" ]; then
        XSESSION_PATH="$HOME_DIR/.xsession"
        echo "[entrypoint] Creating $XSESSION_PATH for user $USER"
        create_singleapp_xsession "$XSESSION_PATH" "$SINGLEAPP"
        chown "$USER":"$USER" "$XSESSION_PATH" 2>/dev/null || true
        chmod 0755 "$XSESSION_PATH" 2>/dev/null || true
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


# Create the ~/.xsession contents for a single-app session.
# Parameters:
#  $1 -> path to write (e.g. /home/user/.xsession)
#  $2 -> SINGLEAPP command line
create_singleapp_xsession() {
    local path="$1"
    local singleapp="$2"

    cat > "$path" <<'XSESSION' 2>/dev/null || true
#!/usr/bin/env bash
set -e
# inherit DISPLAY from the environment (do not hardcode a display number)
# xrdp / sesman provides a per-session DISPLAY; leaving it unchanged
# create a per-session runtime dir that includes the display so multiple
# sessions (even for the same UID) do not conflict
XDG_RUNTIME_DIR="/tmp/xdg-runtime-$(id -u)-${DISPLAY//[^[:alnum:]]/_}"
mkdir -p "$XDG_RUNTIME_DIR" || true
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

# export DISPLAY if provided so tools like xprop use the correct display
if [ -n "${DISPLAY:-}" ]; then
  export DISPLAY
fi

# capture stdout/stderr from this generated session script to a log file
# in the per-session runtime dir so we can debug failures
exec >> "$XDG_RUNTIME_DIR/.xsession.log" 2>&1 || true

# small debug dump for diagnosing why the WM may not start
printf '=== .xsession start: %s PID=%s USER=%s DISPLAY=%s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$(id -un)" "${DISPLAY:-}" 
echo "ENV:" && env
echo "PS:" && ps aux
echo "XPROP ROOT:" && xprop -root _NET_SUPPORTING_WM_CHECK 2>&1 || true
echo "-- end debug header --"

# export XAUTHORITY only if the session provides it; do not force a
# single global ~/.Xauthority which can collide between concurrent sessions
if [ -n "${XAUTHORITY:-}" ]; then
  export XAUTHORITY
fi

# wait briefly for X authority to be usable if present
if [ -n "${XAUTHORITY:-}" ]; then
  for i in $(seq 1 50); do
    [ -r "$XAUTHORITY" ] && break || sleep 0.1
  done
fi

# Start a per-session DBus (so session-managed apps can connect)
if command -v dbus-launch >/dev/null 2>&1; then
  eval "$(dbus-launch --sh-syntax --exit-with-session)" || true
fi

# Start XFCE settings daemon so GTK/xfconf XSETTINGS (theme, icons, fonts)
# are available in this minimal single-app session. Without xfsettingsd
# some apps (menus, toolbar icons) may not display icon theme elements.
if command -v xfsettingsd >/dev/null 2>&1; then
  setsid xfsettingsd >"$XDG_RUNTIME_DIR/xfsettingsd.log" 2>&1 & XS_PID=$! || true
fi

# start a lightweight window manager if none is running on this display
WM_PID=
# xprop may report different messages when the property is missing
# treat the property as present only when a hex window id (0x...) is returned
wm_check=$(xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null || true)
if ! printf '%s' "$wm_check" | grep -q '0x[0-9a-fA-F]'; then
  # prefer openbox (simple standalone WM) then xfwm4
  if command -v openbox >/dev/null 2>&1; then
    echo "[entrypoint] Starting openbox window manager" >&2
    setsid openbox >"$XDG_RUNTIME_DIR/openbox.log" 2>&1 & WM_PID=$! || true
  elif command -v xfwm4 >/dev/null 2>&1; then
    echo "[entrypoint] Starting xfwm4 window manager" >&2
    setsid xfwm4 >"$XDG_RUNTIME_DIR/xfwm4.log" 2>&1 & WM_PID=$! || true
  elif command -v matchbox-window-manager >/dev/null 2>&1; then
    echo "[entrypoint] Starting matchbox-window-manager" >&2
    setsid matchbox-window-manager >"$XDG_RUNTIME_DIR/matchbox.log" 2>&1 & WM_PID=$! || true
  else
    echo "[entrypoint] WARNING: no supported window manager found; windows may be unmanaged" >&2
  fi

  # wait for the window manager to register with the X server (look for 0x id)
  for i in $(seq 1 50); do
    wm_check=$(xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null || true)
    printf '%s' "$wm_check" | grep -q '0x[0-9a-fA-F]' && break || sleep 0.1
  done

  if ! printf '%s' "$wm_check" | grep -q '0x[0-9a-fA-F]'; then
    echo "[entrypoint] WARNING: window manager did not register _NET_SUPPORTING_WM_CHECK; windows may be unmanaged" >&2
    # try xfwm4 as a fallback if available
      if command -v xfwm4 >/dev/null 2>&1 && ! pgrep -x xfwm4 >/dev/null 2>&1; then
      echo "[entrypoint] Attempting to start xfwm4 as fallback" >&2
      setsid xfwm4 >"$XDG_RUNTIME_DIR/xfwm4.log" 2>&1 & WM_PID=$! || true
      sleep 0.5
    fi
  fi
fi

XSESSION
    # write SINGLEAPP assignment (shell-escaped)
    printf 'SINGLEAPP=%q\n' "$singleapp" >> "$path" 2>/dev/null || true
    cat >> "$path" <<'XSESSION_TAIL'
APP_CMD="$SINGLEAPP"
eval "$APP_CMD" &
APP_PID=$!

# Determine whether to avoid aggressive WM/hint tweaks for apps that use
# transient dialogs / internal widgets (terminals, terminal emulators, etc).
# For those, aggressively changing window type / motif hints or marking them
# as DOCK can break focus restore when a dialog closes.
CB=$(basename "$SINGLEAPP" | awk '{print tolower($0)}')
case "$CB" in
  xfce4-terminal|xterm|gnome-terminal|konsole|lxterminal) SKIP_HINTS=1 ;;
  *) SKIP_HINTS=0 ;;
esac

if command -v wmctrl >/dev/null 2>&1; then
  WIN=""
  for i in $(seq 1 80); do
    # try to find window by PID first
    WIN=$(wmctrl -lp 2>/dev/null | awk -v pid=$APP_PID '$3==pid {print $1; exit}') || true
    if [ -n "$WIN" ]; then
      break
    fi
    # fallback: try matching WM_CLASS using the app command basename
    CB_FALLBACK=$(basename "$SINGLEAPP" | awk '{print tolower($0)}')
    WIN=$(wmctrl -lx 2>/dev/null | awk -v cb="$CB_FALLBACK" '{ if (index(tolower($3), cb)) {print $1; exit}}') || true
    [ -n "$WIN" ] && break || sleep 0.1
  done
  if [ -n "$WIN" ]; then
    # try fullscreen first (removes decorations in many WMs), fall back to maximized
    wmctrl -ir "$WIN" -b add,fullscreen >/dev/null 2>&1 || wmctrl -ir "$WIN" -b add,maximized_vert,maximized_horz >/dev/null 2>&1 || true

    # Only apply the more aggressive decoration/state tweaks for non-terminal apps.
    if [ "${SKIP_HINTS:-0}" -eq 0 ] && command -v xprop >/dev/null 2>&1; then
      xprop -id "$WIN" -f _NET_WM_ALLOWED_ACTIONS 32a -set _NET_WM_ALLOWED_ACTIONS _NET_WM_ACTION_CLOSE >/dev/null 2>&1 || true
      # Motif WM hints: flags=2 (decorations field valid), functions=0, decorations=0
      xprop -id "$WIN" -f _MOTIF_WM_HINTS 32c -set _MOTIF_WM_HINTS "0x2, 0x0, 0x0, 0x0, 0x0" >/dev/null 2>&1 || true
    fi

    # WM-specific tweaks: detect WM and apply per-WM best-effort rules.
    WM_NAME=$(wmctrl -m 2>/dev/null | awk -F: '/Name:/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' || true)
    # if openbox, try to add an application rule matching WM_CLASS to
    # disable decorations and force maximized state (modify rc.xml).
    if printf '%s' "$WM_NAME" | grep -qi openbox >/dev/null 2>&1; then
      WC_RAW=$(xprop -id "$WIN" WM_CLASS 2>/dev/null || true)
      WC=$(printf '%s' "$WC_RAW" | awk -F'"' '{print $4}' || true)
      if [ -n "$WC" ] && [ "${SKIP_HINTS:-0}" -eq 0 ]; then
        OPENBOX_RC="$HOME/.config/openbox/rc.xml"
        mkdir -p "$(dirname "$OPENBOX_RC")" || true
        if [ -f "$OPENBOX_RC" ]; then
          cp "$OPENBOX_RC" "$OPENBOX_RC.bak" 2>/dev/null || true
          if grep -q "</applications>" "$OPENBOX_RC" 2>/dev/null; then
            awk -v wc="$WC" 'BEGIN{added=0} /<\/applications>/{ if(!added){ print "  <application class=\"" wc "\">\n    <decor>no</decor>\n    <maximized>yes</maximized>\n  </application>"; added=1 } print; next } {print}' "$OPENBOX_RC" > "$OPENBOX_RC.tmp" && mv "$OPENBOX_RC.tmp" "$OPENBOX_RC" || true
          else
            awk -v wc="$WC" '/<\/openbox_config>/{ print "<applications>\n  <application class=\"" wc "\">\n    <decor>no</decor>\n    <maximized>yes</maximized>\n  </application>\n</applications>"; print; next } {print}' "$OPENBOX_RC" > "$OPENBOX_RC.tmp" && mv "$OPENBOX_RC.tmp" "$OPENBOX_RC" || true
          fi
          command -v openbox >/dev/null 2>&1 && openbox --reconfigure >/dev/null 2>&1 || true
        fi
      fi
    elif printf '%s' "$WM_NAME" | grep -qi xfwm4 >/dev/null 2>&1; then
      # For xfwm4, attempt to hide taskbar/pager entries for the window.
      xprop -id "$WIN" -f _NET_WM_STATE 32a -set _NET_WM_STATE _NET_WM_STATE_SKIP_TASKBAR,_NET_WM_STATE_SKIP_PAGER >/dev/null 2>&1 || true
    fi
    # As a last resort, start a background monitor that watches for the window being
    # iconified (minimized) or losing its maximized state and restores it.
    # The monitor will also attempt to re-discover the window by PID if
    # the X window id changes (some toolkits reparent windows).
    (
      CID="$WIN"
      while kill -0 "$APP_PID" 2>/dev/null; do
        # if the saved XID no longer exists, try to find a new one by PID
        if ! xprop -id "$CID" >/dev/null 2>&1; then
          NEW=$(wmctrl -lp 2>/dev/null | awk -v pid=$APP_PID '$3==pid {print $1; exit}') || true
          [ -n "$NEW" ] && CID="$NEW"
        fi

        state=$(xprop -id "$CID" _NET_WM_STATE 2>/dev/null || true)

        # if hidden (iconified/minimized) then activate and re-maximize
        if printf '%s' "$state" | grep -q '_NET_WM_STATE_HIDDEN'; then
          wmctrl -ia "$CID" >/dev/null 2>&1 || true
          wmctrl -ir "$CID" -b add,maximized_vert,maximized_horz >/dev/null 2>&1 || true
        fi

        # ensure fullscreen is present (preferred) otherwise ensure maximized bits
        if ! printf '%s' "$state" | grep -q '_NET_WM_STATE_FULLSCREEN'; then
          wmctrl -ir "$CID" -b add,fullscreen >/dev/null 2>&1 || true
        fi
        if ! printf '%s' "$state" | grep -q '_NET_WM_STATE_MAXIMIZED_VERT' || ! printf '%s' "$state" | grep -q '_NET_WM_STATE_MAXIMIZED_HORZ'; then
          wmctrl -ir "$CID" -b add,maximized_vert,maximized_horz >/dev/null 2>&1 || true
        fi

        # Re-apply decoration/state hints regularly (best-effort):
        if command -v xprop >/dev/null 2>&1; then
          if [ "${SKIP_HINTS:-0}" -eq 0 ]; then
            xprop -id "$CID" -f _NET_WM_ALLOWED_ACTIONS 32a -set _NET_WM_ALLOWED_ACTIONS _NET_WM_ACTION_CLOSE >/dev/null 2>&1 || true
            xprop -id "$CID" -f _MOTIF_WM_HINTS 32c -set _MOTIF_WM_HINTS "0x2, 0x0, 0x0, 0x0, 0x0" >/dev/null 2>&1 || true
            # set window type to DOCK which often removes decorations (skip for terminals)
            xprop -id "$CID" -f _NET_WM_WINDOW_TYPE 32a -set _NET_WM_WINDOW_TYPE _NET_WM_WINDOW_TYPE_DOCK >/dev/null 2>&1 || true
          fi
        fi

        sleep 0.5
      done
    ) & MONITOR_PID=$!
    # ensure the monitor is killed when the session exits
    trap 'kill ${MONITOR_PID:-0} 2>/dev/null || true' EXIT
  fi
fi

wait "$APP_PID" || true
XSESSION_TAIL


}


# Deterministic runtime hook runner

# Parameters:
#   $1 -> SKIP_ENTRYPOINT_HOOKS (0/1)
#   $2 -> ENTRYPOINT_STRICT (0/1)
#   $3 -> HOOK_ROOT (MANDATORY) - directory containing hooks (e.g. /etc/entrypoint.d)
#   $4 -> USERS_CREDENTIALS (MANDATORY) - name of an array variable (passed by name)
#         containing JSON objects (each element will be passed as a separate
#         argument to the hooks). Use a nameref in the function to access it.
run_entrypoint_hooks() {
    SKIP_HOOKS="${1:-0}"
    ENTRYPOINT_STRICT="${2:-1}"
    HOOK_ROOT="${3:-}"

    [ "${SKIP_HOOKS}" -eq 1 ] && { echo "[entrypoint] SKIPPING hooks due to SKIP_ENTRYPOINT_HOOKS=1"; return 0; }

    if [ -z "${HOOK_ROOT:-}" ]; then
        echo "[entrypoint] ERROR: run_entrypoint_hooks requires HOOK_ROOT (3rd param)" >&2
        exit 1
    fi

    if [ -z "${4:-}" ]; then
      echo "[entrypoint] ERROR: missing USERS_CREDENTIALS (4th param)" >&2; 
      exit 1
    fi
    local -n USERS_CREDENTIALS="$4"


    phases=(pre main post)

    # If no hook dir exists, nothing to do
    shopt -s nullglob 2>/dev/null || true
    for phase in "${phases[@]}"; do
        dir="$HOOK_ROOT/$phase"
        [ -d "$dir" ] || continue

        # Collect and sort hooks in natural order (respects numeric prefixes)
        mapfile -t hooks < <(printf '%s\n' "$dir"/*.sh 2>/dev/null | sort -V) || true
        for hook in "${hooks[@]}"; do
            [ -n "$hook" ] || continue
            [ -f "$hook" ] || continue
            
            echo "[entrypoint] running hook $hook"
            if ! (
              . "$hook"
              if ! declare -f entrypoint_hook >/dev/null 2>&1; then
                echo "[entrypoint] ERROR: hook $hook must define function entrypoint_hook" >&2
                false
              else
                entrypoint_hook users_credentials   # pass the array name so hook can `local -n u="$1"`
              fi
            ); then
              # handle failure per ENTRYPOINT_STRICT
              if [ "${ENTRYPOINT_STRICT}" -eq 1 ]; then
                  echo "[entrypoint] exiting due to hook failure and ENTRYPOINT_STRICT=1" >&2
                  exit 1
              else
                  echo "[entrypoint] continuing despite hook failure (ENTRYPOINT_STRICT!=1)"
              fi
            fi
        done
    done
    shopt -u nullglob 2>/dev/null || true
}

# Load USERS_CREDENTIALS from a secret file or environment and validate.
# Supports USERS_CREDENTIALS provided either as a
# file at /run/secrets/users_credentials (recommended for Docker secrets or
# Kubernetes Secrets mounted as files) or via the environment variable
# USERS_CREDENTIALS. The content must be a JSON array of objects with fields
# `username`, `password` and `sudo` (boolean).
# On success prints the JSON to stdout. Returns non-zero on failure.

load_users_json() {
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
    printf '%s' "$json"
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
