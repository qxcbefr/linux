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
# DNS cascade, first one that resolves wins:
#   1. Docker's embedded resolver (127.0.0.11) - normally the right answer
#   2. Azure/Sandbox internal wire resolver (168.63.129.16) - reachable where
#      the embedded proxy is not (observed in nested docker sandboxes)
#   3. Public resolvers - normal internet
# ---------------------------------------------------------------------------
try_dns() { printf 'nameserver %s\noptions timeout:2 attempts:2\n' "$1" > /etc/resolv.conf && getent hosts archlinux.org >/dev/null 2>&1; }
if ! getent hosts archlinux.org >/dev/null 2>&1; then
  cp /etc/resolv.conf /etc/resolv.conf.docker.bak 2>/dev/null || true
  for ns in 127.0.0.11 168.63.129.16 1.1.1.1 8.8.8.8; do
    if try_dns "$ns"; then
      echo "[cachyos-vnc] DNS fixed via nameserver ${ns}"
      break
    fi
  done
  getent hosts archlinux.org >/dev/null 2>&1 || \
    echo "[cachyos-vnc] WARNING: no working DNS resolver found"
fi

# NM must not rewrite resolv.conf (Docker owns it; NM's DNS list can point at
# resolvers that are blocked in sandboxed environments)
cat > /etc/NetworkManager/conf.d/99-nm-dns.conf <<'EOF'
[main]
dns=none
EOF

# ----------------------------------------------------------------------------
# NetworkManager: give the Plasma network applet a real "Connected" state.
# Docker assigns the container IP itself (no DHCP server on docker bridges),
# so we register the interface with NM as a *manual* (static) connection using
# the exact same address/gateway/DNS -> no network churn, but plasma-nm shows
# a proper active connection instead of "Unknown".
# ----------------------------------------------------------------------------
IFACE="$(ip -4 -o addr show scope global 2>/dev/null | head -1 | awk '{print $2}')"
ADDR="$(ip -4 -o addr show dev "${IFACE}" scope global 2>/dev/null | awk '{print $4}' | head -1)"
GW="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -1)"

mkdir -p /etc/NetworkManager/conf.d /etc/NetworkManager/system-connections
if [ -n "${IFACE}" ] && [ -n "${ADDR}" ]; then
  DNS_LIST="$(awk '/^nameserver/{printf "%s;", $2}' /etc/resolv.conf)"
  cat > "/etc/NetworkManager/system-connections/00-container.nmconnection" <<EOF
[connection]
id=container-net
type=ethernet
interface-name=${IFACE}
autoconnect=true

[ipv4]
method=manual
address1=${ADDR}${GW:+,${GW}}
${DNS_LIST:+dns=${DNS_LIST}}

[ipv6]
method=ignore
EOF
  chmod 600 "/etc/NetworkManager/system-connections/00-container.nmconnection"
  # Interface is now managed via the profile above; drop any stale blacklist
  rm -f /etc/NetworkManager/conf.d/99-docker.conf
else
  # Fallback: couldn't parse the config -> keep NM away from docker's interfaces
  cat > /etc/NetworkManager/conf.d/99-docker.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:eth*;interface-name:enp*;interface-name:veth*

[main]
dns=default
EOF
fi

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
