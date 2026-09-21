#!/bin/bash
# Desktop session launcher (runs as ${USER}, spawned by entrypoint.sh).
# Starts KasmVNC's X server (Xkasmvnc), then the KDE Plasma X11 session on it.
set -e

export HOME="${HOME:-/home/${USER_NAME:-cachyos}}"
export USER="${USER_NAME:-cachyos}"
DISPLAY_NUM=1
export DISPLAY=":${DISPLAY_NUM}"
PORT="${NOVNC_PORT:-6901}"
W="${VNC_RESOLUTION%%x*}"
H="${VNC_RESOLUTION##*x}"
D="${VNC_DEPTH:-24}"

mkdir -p "${HOME}/.vnc" "${HOME}/.cache" "/tmp/xdg-runtime-${USER}"
chmod 700 "${HOME}/.vnc" "/tmp/xdg-runtime-${USER}"
export XDG_RUNTIME_DIR="/tmp/xdg-runtime-${USER}"

# --- KasmVNC user/password database (HTTP Basic auth in the browser client) --
if [ ! -s "${HOME}/.kasmpasswd" ]; then
  printf '%s\n%s\n' "${VNC_PW:-cachyos}" "${VNC_PW:-cachyos}" | kasmvncpasswd -u "${USER}" -w -o >/dev/null 2>&1 || true
fi
if [ ! -s "${HOME}/.kasmpasswd" ]; then
  # Fallback: standard SHA-crypt line (KasmVNC accepts crypt(3) hashes)
  printf '%s:%s\n' "${USER}" "$(printf '%s' "${VNC_PW:-cachyos}" | openssl passwd -6 -stdin)" > "${HOME}/.kasmpasswd"
fi
chmod 600 "${HOME}/.kasmpasswd" 2>/dev/null || true

# --- Self-signed cert (lets you flip network.ssl.require_ssl to true) --------
if [ ! -s "${HOME}/.vnc/self.pem" ]; then
  openssl req -x509 -newkey rsa:2048 -keyout /tmp/k.key -out /tmp/k.crt \
    -nodes -subj "/CN=cachyos-vnc" -days 3650 2>/dev/null && \
    cat /tmp/k.crt /tmp/k.key > "${HOME}/.vnc/self.pem" && rm -f /tmp/k.key /tmp/k.crt
fi
chmod 600 "${HOME}/.vnc/self.pem" 2>/dev/null || true

# --- Start KasmVNC X server ---------------------------------------------------
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null || true
echo "[cachyos-vnc] starting Xkasmvnc on :${DISPLAY_NUM} (web client on port ${PORT})"
/usr/bin/Xkasmvnc ":${DISPLAY_NUM}" \
  -geometry "${W}x${H}" \
  -depth "${D}" \
  -websocketPort "${PORT}" \
  -interface 0.0.0.0 \
  -httpd /usr/share/kasmvnc/www \
  -KasmPasswordFile "${HOME}/.kasmpasswd" \
  -sslOnly off \
  -AlwaysShared -AcceptCutText -SendCutText &
XVNC_PID=$!

for _ in $(seq 1 40); do
  [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ] && break
  if ! kill -0 "$XVNC_PID" 2>/dev/null; then
    echo "[cachyos-vnc] Xkasmvnc failed to start; logs: ${HOME}/.vnc/*.log" >&2
    exit 1
  fi
  sleep 0.25
done

# --- Session D-Bus + KDE Plasma ----------------------------------------------
eval "$(dbus-launch --sh-syntax)" 2>/dev/null || true
export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
export XDG_CURRENT_DESKTOP=KDE DESKTOP_SESSION=plasma KDE_FULL_SESSION=true
export QT_QPA_PLATFORM=xcb

startplasma-x11 &
PLASMA_PID=$!

term() {
  kill "${PLASMA_PID}" "${XVNC_PID}" 2>/dev/null || true
  [ -n "${DBUS_SESSION_BUS_PID}" ] && kill "${DBUS_SESSION_BUS_PID}" 2>/dev/null || true
  exit 0
}
trap term SIGTERM SIGINT

# If the X server or Plasma dies, tear the session down
wait -n "${XVNC_PID}" "${PLASMA_PID}"
term
