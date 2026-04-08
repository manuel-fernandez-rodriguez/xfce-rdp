FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install mimimum dependencies for a functional XFCE desktop environment with 
# XRDP support, plus some common utilities and tools.
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
        jq \
        gnupg \
        ca-certificates \
        apt-transport-https \
        gvfs \
        gvfs-backends \
        tumbler \
        librsvg2-common \
        at-spi2-core \
        pm-utils \
        xdg-utils \
        wmctrl \
        # Theme / engine packages to provide a dark GTK theme and icons
        arc-theme \
        gtk2-engines-pixbuf \
        gtk2-engines-murrine \
        adwaita-icon-theme \
        gnome-themes-extra \
    && apt-get autoremove -y --purge \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /usr/share/doc/* /usr/share/man/* /usr/share/locale/*

# Ensure a minimal system locale file exists so PAM modules that read
# /etc/default/locale do not warn when it is missing in minimal containers.
RUN printf 'LANG=C.UTF-8\n' > /etc/default/locale || true && chmod 0644 /etc/default/locale || true

# Unset, so that it is not propagated to the container at runtime
ENV DEBIAN_FRONTEND=

# Who can run the X server? Allow anybody
RUN printf 'allowed_users=anybody\n' > /etc/X11/Xwrapper.config && \
    chmod 0444 /etc/X11/Xwrapper.config && \
    chmod +x /usr/share/xsessions/startxfce4 || true

# Copy the custom startwm.sh script into the image to set up the XRDP session to launch XFCE.
COPY startwm.sh /etc/xrdp/startwm.sh

# Copy entrypoint and helper scripts
COPY entrypoint.sh entrypoint_helpers.sh startwm_helpers.sh hooks.sh runtime_config.sh /etc/xfce-rdp/

# Apply the appropiate permissions to the scripts. startwm.sh must be executable by xrdp, 
# and the entrypoint and helper scripts should be readable by all users but only writable by root.
RUN chmod +x /etc/xrdp/startwm.sh && \
    chmod +x /etc/xfce-rdp/entrypoint.sh && \
    chmod 644 /etc/xfce-rdp/entrypoint_helpers.sh /etc/xfce-rdp/startwm_helpers.sh /etc/xfce-rdp/hooks.sh /etc/xfce-rdp/runtime_config.sh || true

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

# Provide system-wide XFCE defaults so new users get the Arc-Dark appearance
RUN mkdir -p /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
COPY xfce-defaults/xsettings.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml
COPY xfce-defaults/xfwm4.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml

# Populate /etc/skel so users created with `useradd -m` receive the XFCE defaults
RUN mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml && \
    cp /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/* /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/ && \
    # ensure skel xsettings uses flat layout and permissions
    chmod -R 0644 /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml || true

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

# Lock root and disallow graphical xrdp logins for root:
#  - `passwd -l root` locks the account password (safer than removing it)
#  - change root shell to nologin to prevent interactive sessions
#  - insert a PAM rule into xrdp-sesman that explicitly rejects user root
RUN passwd -l root || true && \
    usermod -s /usr/sbin/nologin root || true && \
    if [ -f /etc/pam.d/xrdp-sesman ] && ! grep -q 'pam_succeed_if.so user != root' /etc/pam.d/xrdp-sesman; then \
      # insert near top to reject root before session setup
      sed -i '1i auth    required    pam_succeed_if.so user != root quiet' /etc/pam.d/xrdp-sesman || true; \
    fi

# Expose XRDP port
EXPOSE 3389

ENTRYPOINT ["/etc/xfce-rdp/entrypoint.sh"]
