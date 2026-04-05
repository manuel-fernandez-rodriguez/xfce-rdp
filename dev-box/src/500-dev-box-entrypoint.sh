#!/usr/bin/env bash

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


entrypoint_hook() {
    local -n user_data="$1"    # nameref to caller's array

    echo "[entrypoint] Hook started" >&2
  
    # Make global VS Code extensions available to the runtime user by creating
    # a per-user extension path that points to the global extensions installed
    # at build time. Prefer a symlink, fall back to copying if symlink fails.
    # Ensure global VS Code extensions are available for any created users.
    if [ -d "/usr/share/code/extensions" ]; then
        for u in "${user_data[@]}"; do
            [ -z "$u" ] && continue
            username=$(jq -r '.username // empty' <<<"$u")
            USER_VSCODE_DIR="/home/$username/.vscode"
            USER_EXT_DIR="$USER_VSCODE_DIR/extensions"
            if [ ! -e "$USER_EXT_DIR" ]; then
                echo "[entrypoint] Installing VSCode extensions for $username" >&2
                mkdir -p "$USER_VSCODE_DIR" || true
                cp -a /usr/share/code/extensions "$USER_EXT_DIR" 2>/dev/null || true
                chown -R "$username":"$username" "/home/$username/.vscode" 2>/dev/null || true
            fi
        done
    fi

    # Find any Chromium/Electron "chrome-sandbox" helpers, make them owned by root
    # and set the setuid bit so sandbox helpers can operate inside container.
    disable_electron_sandbox
}