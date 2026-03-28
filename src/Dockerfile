FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        sudo \
        xfce4 \
        xfce4-goodies \
        xorg \
        xrdp \
        pipewire \
        pipewire-pulse \
        wireplumber \
        pipewire-module-xrdp \
        pipewire-audio-client-libraries \
        rtkit \
        pulseaudio-utils \
        dbus \
        dbus-x11 \
        gnome-keyring \
        libpam-gnome-keyring \
        libsecret-1-0 \
        xserver-xorg-core \
        xorgxrdp \
        git \
        jq \
        firefox-esr \
        wget \
        curl \
        gnupg \
        ca-certificates \
        apt-transport-https \
        gvfs \
        gvfs-backends \
        tumbler \
        librsvg2-common \
        adwaita-icon-theme \
        at-spi2-core \
        pm-utils \
    && apt-get autoremove -y --purge \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /usr/share/doc/* /usr/share/man/* /usr/share/locale/*

# Install Visual Studio Code
RUN wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg && \
    install -o root -g root -m 644 microsoft.gpg /etc/apt/trusted.gpg.d/ && \
    sh -c 'echo "deb [arch=amd64] https://packages.microsoft.com/repos/vscode stable main" > /etc/apt/sources.list.d/vscode.list' && \
    apt-get update && \
    apt-get install -y --no-install-recommends code && \
    apt-get autoremove -y --purge && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* microsoft.gpg /usr/share/doc/* /usr/share/man/* /usr/share/locale/*

# Make sure any chrome-sandbox helper installed with VS Code is owned by
# root and has the setuid bit so Chromium/Electron sandbox helpers can
# create namespaces inside Docker's default seccomp profile.
RUN for f in /usr/share/code/chrome-sandbox /usr/lib/code/chrome-sandbox /opt/visual-studio-code/chrome-sandbox; do \
      if [ -f "$f" ]; then \
        chown root:root "$f" || true; \
        chmod a+x "$f" || true; \
        chmod 4755 "$f" || true; \
      fi; \
    done || true


# Install c# extensions for Visual Studio Code (installed as root so they
# are available to any user created at runtime).
ENV DONT_PROMPT_WSL_INSTALL=1

# Make sure VS Code can find the .NET SDK by configuring the extension's settings to point to the system-wide dotnet path.
# The settings are copied to /etc/skel so they are present in any new user's home directory at runtime.
RUN mkdir -p /tmp/.vscode-root/User && \
    printf '{ "dotnetAcquisitionExtension.existingDotnetPath": [ { "extensionId": "ms-dotnettools.csdevkit", "path": "/usr/share/dotnet/dotnet" }, { "extensionId": "ms-dotnettools.csharp", "path": "/usr/share/dotnet/dotnet" } ] }' > /tmp/.vscode-root/User/settings.json && \
    mkdir -p /etc/skel/.config/Code/User && \
    cp /tmp/.vscode-root/User/settings.json /etc/skel/.config/Code/User/settings.json

# Install extensions into a global extensions directory so they are available
# to any user created at runtime. Running the `code` CLI as root requires
# a user-data-dir and --no-sandbox; install into `/usr/share/code/extensions`.
RUN mkdir -p /usr/share/code/extensions && \
    chown root:root /usr/share/code/extensions && \
    code --extensions-dir /usr/share/code/extensions --user-data-dir /tmp/.vscode-root --no-sandbox --install-extension ms-dotnettools.csdevkit --force

# Create wrapper for VS Code to disable Chromium sandbox inside container
RUN printf '#!/bin/sh\nexec /usr/bin/code --no-sandbox --disable-gpu "$@"\n' > /usr/local/bin/code && \
    chmod +x /usr/local/bin/code

# Ensure ELECTRON_DISABLE_SANDBOX is exported system-wide so desktop sessions
# inherit it, and place a wrapper in /usr/bin to reliably override packaged
# launcher when applications start VS Code from menus or shortcuts.
RUN printf 'export ELECTRON_DISABLE_SANDBOX=1\n' > /etc/profile.d/disable-electron-sandbox.sh && \
    chmod 644 /etc/profile.d/disable-electron-sandbox.sh && \
    printf '#!/bin/sh\nexec /usr/share/code/code --no-sandbox --disable-gpu "$@"\n' > /usr/bin/code && \
    chmod +x /usr/bin/code || true


# Install .NET 10 SDK via Microsoft's apt repository
RUN wget https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb -O packages-microsoft-prod.deb && \
    dpkg -i packages-microsoft-prod.deb && \
    rm packages-microsoft-prod.deb && \
    apt-get update && \
    apt-get install -y dotnet-sdk-10.0 && \
    apt-get autoremove -y --purge && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /usr/share/doc/* /usr/share/man/* /usr/share/locale/*

ENV DOTNET_ROOT=/usr/share/dotnet
ENV PATH="$PATH:/usr/share/dotnet"


RUN printf 'allowed_users=anybody\n' > /etc/X11/Xwrapper.config && \
    chmod 0444 /etc/X11/Xwrapper.config && \
    chmod +x /usr/share/xsessions/startxfce4 || true

COPY startwm.sh /etc/xrdp/startwm.sh
RUN chmod +x /etc/xrdp/startwm.sh

# Copy entrypoint which will apply a runtime password from a Docker secret or environment
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY entrypoint_helpers.sh /usr/local/bin/entrypoint_helpers.sh
RUN chmod +x /usr/local/bin/entrypoint.sh && chmod 644 /usr/local/bin/entrypoint_helpers.sh || true

# Allow consumers to persist user home directories by mounting a volume at /home.
# This lets user homes survive container recreation; ownership is adjusted at
# startup only when necessary by the entrypoint.
VOLUME ["/home"]

# Prefer a 24-bit default depth so X and xrdp negotiate a 24bpp visual.
RUN mkdir -p /etc/X11/xorg.conf.d && \
    printf 'Section "Screen"\n\tIdentifier "Screen0"\n\tDefaultDepth 24\n\tSubSection "Display"\n\t\tDepth 24\n\tEndSubSection\nEndSection\n' > /etc/X11/xorg.conf.d/99-xrdp-depth.conf

# Ensure xrdp only advertises up to 24 bpp so clients must use 24-bit True Color.
# If a max_bpp setting exists, replace it; otherwise add it under [globals].
RUN if [ -f /etc/xrdp/xrdp.ini ]; then \
      if grep -q '^max_bpp=' /etc/xrdp/xrdp.ini; then \
        sed -i 's/^max_bpp=.*/max_bpp=24/' /etc/xrdp/xrdp.ini; \
      else \
        sed -i '/^\[globals\]/a max_bpp=24' /etc/xrdp/xrdp.ini; \
      fi; \
    fi

# Configure PAM for xrdp-sesman to auto-unlock the GNOME keyring on login.
# Insert pam_gnome_keyring lines into /etc/pam.d/xrdp-sesman if the file exists
# and the lines are not already present.
RUN if [ -f /etc/pam.d/xrdp-sesman ]; then \
      if ! grep -q pam_gnome_keyring.so /etc/pam.d/xrdp-sesman; then \
        # Try to insert after @include/common-auth and @include/common-session
        sed -i '/^@include common-auth/ a auth optional pam_gnome_keyring.so' /etc/pam.d/xrdp-sesman || true; \
        sed -i '/^@include common-session/ a session optional pam_gnome_keyring.so auto_start' /etc/pam.d/xrdp-sesman || true; \
        sed -i '/^auth include common-auth/ a auth optional pam_gnome_keyring.so' /etc/pam.d/xrdp-sesman || true; \
        sed -i '/^session include common-session/ a session optional pam_gnome_keyring.so auto_start' /etc/pam.d/xrdp-sesman || true; \
        # Fallback: append to the end
        echo 'auth optional pam_gnome_keyring.so' >> /etc/pam.d/xrdp-sesman; \
        echo 'session optional pam_gnome_keyring.so auto_start' >> /etc/pam.d/xrdp-sesman; \
      fi; \
    fi

# Remove root password
RUN passwd -d root


# Expose XRDP port
EXPOSE 3389

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
