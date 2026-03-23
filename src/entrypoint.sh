#!/bin/sh
set -e

# Entrypoint: set user password from Docker secret or environment, then exec the command.
# Use USER_NAME (with underscore) for the runtime username environment variable.
USER_NAME=${USER_NAME:-developer}

# Helper to ensure the runtime user exists and is configured.
create_user() {
  if ! id "$1" >/dev/null 2>&1; then
    echo "[entrypoint] Creating user '$1'"
    useradd -m -s /bin/bash "$1" || true
    if [ "$1" != "root" ]; then
      echo "$1 ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$1 || true
      chmod 0440 /etc/sudoers.d/$1 || true
    fi
    # Ensure home directory ownership is correct. If /home/<user> is a
    # mounted volume it may already exist and be owned by root or another
    # UID; only change ownership when it doesn't match the user's UID to
    # avoid clobbering data/permissions unnecessarily.
    HOME_DIR="/home/$1"
    if [ -d "$HOME_DIR" ]; then
      owner_uid=$(stat -c '%u' "$HOME_DIR" 2>/dev/null || true)
      user_uid=$(id -u "$1" 2>/dev/null || true)
      if [ -z "$owner_uid" ] || [ "$owner_uid" != "$user_uid" ]; then
        echo "[entrypoint] Setting ownership of $HOME_DIR to $1:$1"
        chown -R "$1":"$1" "$HOME_DIR" 2>/dev/null || true
      else
        echo "[entrypoint] Home directory $HOME_DIR already owned by user (uid=$user_uid); skipping chown"
      fi
    else
      mkdir -p "$HOME_DIR" 2>/dev/null || true
      chown -R "$1":"$1" "$HOME_DIR" 2>/dev/null || true
    fi
  fi
}

# Ensure the runtime user exists (create if missing) so USERNAME can be chosen
# at container start time without baking it into the image.
create_user "$USER_NAME"

# Make global VS Code extensions available to the runtime user by creating
# a per-user extension path that points to the global extensions installed
# at build time. Prefer a symlink, fall back to copying if symlink fails.
if [ -d "/usr/share/code/extensions" ]; then
  USER_VSCODE_DIR="/home/$USER_NAME/.vscode"
  USER_EXT_DIR="$USER_VSCODE_DIR/extensions"
  if [ ! -e "$USER_EXT_DIR" ]; then
    mkdir -p "$USER_VSCODE_DIR" || true
    # Force copy global extensions into the user's VS Code extensions dir so
    # extensions are available even when symlinks are problematic on some
    # platforms or storage drivers.
    cp -a /usr/share/code/extensions "$USER_EXT_DIR" 2>/dev/null || true
    # Ensure the user owns their VS Code config.
    chown -R "$USER_NAME":"$USER_NAME" "/home/$USER_NAME/.vscode" 2>/dev/null || true
  fi
fi

# Prefer Docker secret file at /run/secrets/user_password
if [ -f /run/secrets/user_password ]; then
  PW=$(cat /run/secrets/user_password)
elif [ -n "$USER_PASSWORD" ]; then
  PW="$USER_PASSWORD"
fi

if [ -n "$PW" ]; then
  # create_user() above ensures the account exists; attempt to set the
  # password and report failure if chpasswd fails.
  if echo "$USER_NAME:$PW" | chpasswd 2>/dev/null; then
    :
  else
    echo "[entrypoint] Failed to set password for user '$USER_NAME'" >&2
  fi
  # Unset to avoid leaking in the environment
  unset USER_PASSWORD
fi

  # Ensure any Chromium/Electron "chrome-sandbox" helper is owned by root and
  # has the setuid bit set so the native sandbox helper can run without
  # requiring an unconfined seccomp profile. This is more secure than
  # disabling seccomp and allows the sandbox to work inside Docker's default
  # profile.
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

  # As a fallback, export an environment variable and the --no-sandbox flag
  # are already added in the /usr/local/bin/code wrapper. Some Electron builds
  # also respect ELECTRON_DISABLE_SANDBOX.
  export ELECTRON_DISABLE_SANDBOX=1


# If no args provided, run the default xrdp startup command
if [ $# -eq 0 ]; then  
  exec /bin/bash -lc "mkdir -p /run/dbus && dbus-daemon --system --fork || true; /usr/sbin/xrdp-sesman --nodaemon & /usr/sbin/xrdp --nodaemon"
else
  exec "$@"
fi
