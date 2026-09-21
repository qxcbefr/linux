#!/bin/bash
# Entrypoint for the CachyOS + KDE Plasma + KasmVNC container.
#
# Runs as root: fixes DNS, starts system D-Bus + NetworkManager (so the Plasma
# network applet works), then drops to $USER and starts Xkasmvnc (KasmVNC's X
# server with a built-in web client) which launches the Plasma session.

set -e

NOVNC_PORT="${NOVNC_PORT:-6901}"          # KasmVNC web (websocket+http) port
VNC_RESOLUTION="${VNC_RESOLUTION:-1600x900}"
VNC_DEPTH="${VNC_DEPTH:-24}"
USER_NAME="${USER_NAME:-cachyos}"
USER_HOME="/home/${USER_NAME}"

# ---------------------------------------------------------------------------
# DNS fix: Docker copies the host's /etc/resolv.conf, which often points at
# systemd-resolved (127.0.0.53) or a VPN resolver that is unreachable from
# inside the container -> "no internet". If the current resolver can't resolve
# a name, rewrite resolv.conf with public resolvers.
# ---------------------------------------------------------------------------
if ! getent hosts archlinux.org >/dev/null 2>&1; then
  echo "[cachyos-vnc] DNS check failed -> falling back to public resolvers"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\noptions timeout:2 attempts:2\n' > /etc/resolv.conf
fi

# Keep NetworkManager from fighting Docker's interface management
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-docker.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:eth*;interface-name:enp*;interface-name:veth*

[main]
dns=default
EOF

# System D-Bus (required by NetworkManager and the Plasma session)
mkdir -p /run/dbus
rm -f /run/dbus/pid /var/run/dbus/pid 2>/dev/null || true
dbus-daemon --system --fork

# NetworkManager daemon -> makes the Plasma network applet work ("NetworkManager
# is not running" happens because NM was never started, only its applet existed)
/usr/bin/NetworkManager --no-daemon &
NM_PID=$!

# Give NM a moment to come up (don't block forever if it doesn't)
for _ in $(seq 1 20); do
  nmcli general status >/dev/null 2>&1 && break
  sleep 0.5
done

# Logs end up on the container's stdout
mkdir -p /var/log/journal

# ---------------------------------------------------------------------------
# Drop privileges and run the desktop session as ${USER}
# ---------------------------------------------------------------------------
export NOVNC_PORT VNC_RESOLUTION VNC_DEPTH
chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.vnc" "${USER_HOME}/.cache" "${USER_HOME}/.config" 2>/dev/null || true

# Stop cleanly when the container is signaled
term() {
  echo "[cachyos-vnc] shutting down"
  kill "${XVNC_PID:-}" "${NM_PID:-}" 2>/dev/null || true
  kill -TERM "${KASMVNC_PID:-}" 2>/dev/null || true
  exit 0
}
trap term SIGTERM SIGINT

# Run KasmVNC (which spawns Xkasmvnc + Plasma via ~/.vnc/xstartup) as the user
# in its own process group so we can tear the whole session down on exit.
setsid runuser -u "${USER_NAME}" -- /usr/local/bin/start-desktop.sh &
KASMVNC_PID=$!

wait "${KASMVNC_PID}" || true
term
