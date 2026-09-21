# syntax=docker/dockerfile:1
#
# CachyOS (Arch-based, perf-optimized) desktop in Docker, streamed by KasmVNC 1.5.0.
# Stages:
#   1) rootfs  : archlinux base -> add CachyOS repos/keyring -> full CachyOS upgrade
#   2) desktop : install KDE Plasma + KasmVNC + NetworkManager and wire everything up
#
# Build:  docker build -t cachyos-vnc .
# Run:    docker run -d -p 6901:6901 cachyos-vnc
#         Web  -> http://localhost:6901  (KasmVNC browser client, user: cachyos / pw: ${VNC_PW:-cachyos})

FROM archlinux:base-devel AS rootfs

# Base tooling
RUN pacman -Syu --noconfirm && \
    pacman -S --needed --noconfirm pacman-contrib git openssh sudo curl wget ca-certificates && \
    rm -rf /var/cache/pacman/*

# Generate en_US.UTF-8 locale
RUN sed -i 's/^#en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen

# Switch to CachyOS repositories (static mirrorlists pinned to correct repo layout:
# x86_64/cachyos and x86_64_v3/{cachyos-v3,cachyos-core-v3,cachyos-extra-v3})
COPY pacman.conf /etc/pacman.conf
COPY cachyos-mirrorlist /etc/pacman.d/cachyos-mirrorlist
COPY cachyos-v3-mirrorlist /etc/pacman.d/cachyos-v3-mirrorlist

# Trust CachyOS signing key (fetched over HTTPS; HKP keyservers are often blocked)
# and fully upgrade to CachyOS packages
RUN pacman-key --init && \
    curl -fsSL https://raw.githubusercontent.com/CachyOS/CachyOS-PKGBUILDS/master/cachyos-keyring/cachyos.gpg -o /tmp/cachyos.gpg && \
    pacman-key --add /tmp/cachyos.gpg && \
    pacman-key --lsign-key F3B607488DB35A47 && \
    pacman -Sy --noconfirm cachyos-keyring cachyos-mirrorlist cachyos-hooks && \
    pacman -Syu --noconfirm && \
    rm -rf /var/cache/pacman/* /tmp/cachyos.gpg

FROM rootfs AS desktop

ENV LANG=en_US.UTF-8 \
    TERM=xterm-256color

# ---------------------------------------------------------------------------
# KasmVNC 1.5.0 (its own X server + built-in browser client, much smoother
# than TigerVNC+noVNC). No Arch/AUR package exists, so install the official
# Debian trixie build directly (checksum-pinned) and pull the matching Arch
# runtime libs alongside it.
# ---------------------------------------------------------------------------
ARG KASMVNC_VERSION=1.5.0
RUN curl -fsSL --retry 3 \
      -o /tmp/kasmvnc.deb \
      "https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/kasmvncserver_trixie_${KASMVNC_VERSION}_amd64.deb" && \
    echo "80b241de7dfe53bba2b7e1cc5ac8c5246d72271efa16be2d4f76607f30fab1c4  /tmp/kasmvnc.deb" | sha256sum -c - && \
    bsdtar -xOf /tmp/kasmvnc.deb data.tar.xz | bsdtar -xf - -C / && \
    rm -f /tmp/kasmvnc.deb && \
    chmod 755 /usr/share/kasmvnc/www

# Runtime libs required by /usr/bin/Xkasmvnc (verified via the Debian package
# Depends + ldd): X11 client libs, libXfont2, libxshmfence, libGL/gbm (mesa),
# pixman, bsd, unwind, openssl, freetype + xkb tooling/data and X fonts.
RUN pacman -Syu --needed --noconfirm \
      networkmanager \
      plasma-workspace plasma-x11-session kwin-x11 \
      plasma-desktop plasma-nm \
      dolphin konsole kate spectacle ark gwenview plasma-systemmonitor \
      breeze breeze-gtk \
      firefox \
      ttf-dejavu noto-fonts \
      xorg-xauth xorg-xkbcomp xkeyboard-config \
      xorg-fonts-100dpi xorg-fonts-75dpi xorg-fonts-encodings \
      libxfont2 libxshmfence libglvnd mesa intel-media-driver mesa-utils \
      libbsd libunwind pixman openssl \
      shared-mime-info \
      nano vim xterm \
      dbus dbus-glib \
    # Perl modules used by kasmvncpasswd/kasmvncserver (best-effort: a missing
    # module must not break the build; start-desktop.sh has an openssl fallback
    # for the password file if the perl tooling can't run)
    && (pacman -S --needed --noconfirm \
         perl-datetime perl-datetime-timezone perl-try-tiny perl-list-moreutils \
         perl-yaml-tiny perl-switch 2>/dev/null || true) \
    && glib-compile-schemas /usr/share/glib-2.0/schemas/ \
    && update-mime-database /usr/share/mime \
    && (update-desktop-database /usr/share/applications || true) \
    && (gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor /usr/share/icons/breeze 2>/dev/null || true) \
    && pacman -Scc --noconfirm

# KasmVNC config (GPU/DRI3 node, encoding tuning, plain ws:// for local use)
COPY kasmvnc.yaml /etc/kasmvnc/kasmvnc.yaml

# X server writes compiled keymaps here; make it writable for the session user
RUN mkdir -p /var/lib/xkb && chmod 1777 /var/lib/xkb

# Non-root user
ARG USER=cachyos
ARG UID=1000
RUN useradd -m -u ${UID} -G wheel,video,audio,render,input -s /bin/bash ${USER} && \
    echo "${USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/${USER}

# Session config (Plasma look & feel + baloo off)
# NOTE: use explicit /home/${USER} paths — ${HOME} is not defined at build time
COPY --chown=${USER}:${USER} kde/ /home/${USER}/.config/
COPY --chown=${USER}:${USER} xstartup /home/${USER}/.vnc/xstartup
COPY start-desktop.sh /usr/local/bin/start-desktop.sh
RUN chmod +x /home/${USER}/.vnc/xstartup /usr/local/bin/start-desktop.sh && \
    mkdir -p /home/${USER}/.vnc /home/${USER}/.cache && \
    chown -R ${USER}:${USER} /home/${USER}/.vnc /home/${USER}/.config

# Needed for gdk-pixbuf/glycin image loaders inside the container
ENV XDG_DATA_DIRS=/usr/share \
    GLYCIN_DISABLE_SANDBOX=i-know-the-risks

EXPOSE 6901/udp 6901/tcp

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Entrypoint starts as root (NetworkManager + D-Bus need it), then drops
# privileges to ${USER} for the desktop session.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
