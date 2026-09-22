# linux

CachyOS (Arch-based, performance-optimized) desktop running in Docker with the
**KDE Plasma** desktop, streamed by **KasmVNC 1.5.0** to your browser.

## What's inside

- CachyOS repositories + keyring on top of an Arch `base-devel` rootfs (fully upgraded to CachyOS packages)
- **KDE Plasma 6** (X11 session) — KWin, Dolphin, Konsole, Kate, Spectacle, Ark, Gwenview, plasma-systemmonitor
- **KasmVNC 1.5.0** — its own X server with a built-in browser client (webp/jpeg encoding, WebRTC UDP transit, DRI3 GPU acceleration). No TigerVNC/noVNC needed; legacy VNC clients are not supported by design.
- **NetworkManager running** (with system D-Bus) so the Plasma network applet actually works
- DNS health check with public-resolver fallback (fixes "no internet" caused by inheriting the host's `127.0.0.53` stub)
- GPU-ready: mesa/VAAPI/NVENC libs + DRI3 enabled (needs device passthrough, see below)

## Build & run

**Recommended: use compose** (it sets `container_name: cachyos-vnc`, so don't mix with a manual `docker run --name cachyos-vnc` — the name would conflict):

```bash
docker compose up -d --build   # build + start
docker compose logs -f         # watch logs
docker compose restart         # restart
docker compose down            # stop + remove
```

**Or manually:**

```bash
docker build -t cachyos-vnc .

docker run -d --name cachyos-vnc \
  -p 6901:6901/tcp -p 6901:6901/udp \
  -e VNC_PW=cachyos \
  -e VNC_RESOLUTION=1600x900 \
  cachyos-vnc

docker logs -f cachyos-vnc
```

> If you hit `Conflict. The container name "/cachyos-vnc" is already in use`, remove the existing container first: `docker rm -f cachyos-vnc`.

## Connect

| Method  | Address          | Login |
|---------|------------------|-------|
| Browser | http://localhost:6901 | `cachyos` / `$VNC_PW` (default `cachyos`) |

KasmVNC shows an HTTP Basic auth prompt — enter the username `cachyos` and the
`VNC_PW` password. The desktop auto-resizes to your browser window.

> Plain `ws://` is enabled for localhost use. For remote exposure set
> `network.ssl.require_ssl: true` in `kasmvnc.yaml` (a self-signed cert is
> generated at `~/.vnc/self.pem`) and put a reverse proxy with TLS in front.n

## GPU acceleration

The container ships mesa + VAAPI (Intel/AMD) and the KasmVNC config enables
DRI3 with `/dev/dri/renderD128`. To actually use the host GPU:

```bash
# Intel/AMD
docker run -d --name cachyos-vnc --device /dev/dri -p 6901:6901/tcp -p 6901:6901/udp cachyos-vnc

# NVIDIA (host needs nvidia-container-toolkit)
docker run -d --name cachyos-vnc --gpus all \
  -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all \
  -p 6901:6901/tcp -p 6901:6901/udp cachyos-vnc
```

In compose, uncomment the `devices:` / `deploy:` GPU blocks in `docker-compose.yml`.
Without a passed-through GPU everything still works — KasmVNC falls back to CPU
encoding, and KWin uses its lightweight XRender backend.

## Network (why the applet said "NetworkManager is not running")

The old image installed only `network-manager-applet`, never the `NetworkManager`
daemon, and there was no system D-Bus. Now the entrypoint:

1. Checks DNS and falls back to `1.1.1.1 / 8.8.8.8 / 9.9.9.9` if the inherited
   host resolver (e.g. systemd-resolved stub) doesn't work in the container.
2. Starts the **system D-Bus**, then **NetworkManager**.

Note: Docker owns the container's `eth0`; there is no Wi-Fi inside a container.
The applet now shows a healthy NM with the docker interface *unmanaged* (by
design, via `/etc/NetworkManager/conf.d/99-docker.conf`), and apps get working
DNS. To customize DNS, add `dns: [1.1.1.1, 8.8.8.8]` in compose or `--dns` flags.

## Configuration (env vars)

| Variable        | Default     | Description                     |
|-----------------|-------------|---------------------------------|
| `VNC_PW`        | `cachyos`   | KasmVNC password (user: `cachyos`) |
| `NOVNC_PORT`    | `6901`      | KasmVNC web (websocket/HTTP) port |
| `VNC_RESOLUTION`| `1600x900`  | Initial desktop size (auto-resizes to the browser) |
| `VNC_DEPTH`     | `24`        | Color depth                     |

## Notes

- Only `linux/amd64` (x86-64-v3 optimized CachyOS repos; KasmVNC ships amd64 packages). ARM isn't supported by the CachyOS repos.
- KasmVNC **is not** a traditional VNC server — connect with a browser (or any KasmVNC-aware client), not a classic VNC viewer.
- Streaming smoothness tips: the client's side-panel lets you tune quality/FPS; UDP transit (`6901/udp`) improves fluency on LAN; UI animations are disabled by default (`kde/kdeglobals`, `kde/kwinrc`).
- To persist your home directory, mount a volume: `-v cachyos-home:/home/cachyos`.
- KasmVNC is installed from the official Debian `trixie` 1.5.0 package (checksum-pinned in the Dockerfile) since no Arch/AUR package exists; its Arch runtime dependencies are installed alongside it.
