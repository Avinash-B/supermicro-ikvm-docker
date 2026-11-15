# supermicro-ikvm-docker

Run the legacy Supermicro / ATEN Java iKVM remote console inside a Linux
container and reach it from any VNC client. This exists for machines that
cannot run the old viewer directly, such as Apple Silicon Macs.

## Why this exists

Older Supermicro boards (X8 / X9 generation, ATEN / Nuvoton WPCM450 BMC) give
you only one way to see the server's screen and use its keyboard and mouse: a
Java Web Start application (`iKVM.jar`). On a current computer that path is
blocked on several sides at once:

- **The viewer crashes on modern macOS.** Its native libraries are from about
  2010, are x86_64 only, and call Objective-C / AppKit routines that no longer
  exist. On an Apple Silicon Mac it needs Rosetta and an old Java, and even then
  it dies in its own native code (for example in a keyboard-LED routine, then on
  a bus error in its video path).
- **Standard VNC clients cannot connect.** The console on TCP port 5900 speaks
  RFB, but the board advertises only security type 16 and then runs a
  proprietary handshake (it also uses UDP 623). A normal VNC client, including
  macOS Screen Sharing, cannot authenticate to it directly.
- **There is no HTML5 console** on this firmware, and **IPMI-over-LAN is often
  disabled**, so `ipmitool` serial-over-LAN is not available either.

The one component that *does* speak the proprietary protocol correctly is the
vendor's own viewer. The viewer also ships a **Linux** build whose native
libraries do not touch macOS APIs. So the fix is to run that Linux build in a
Linux container and send only its screen to your Mac.

## What this does

```
  your Mac                         Docker container (linux/amd64)              the server
  ----------                       -------------------------------             ----------
  VNC client   --- VNC/5901 --->   x11vnc -> Xvfb display -> iKVM.jar  --- 5900/623 --->  BMC / iKVM
  (Screen Sharing)                 (Java 8 + ATEN Linux native libs)         (proprietary RFB)
```

The container:

1. Logs in to the BMC over HTTP to get a session token.
2. Reads the board's own JNLP descriptor to learn the exact viewer version, the
   Linux native library, the main class, and the launch arguments.
3. Downloads that viewer from the BMC and unpacks it (`pack200`).
4. Starts a virtual X display (`Xvfb`), a light window manager (`fluxbox`), and a
   VNC server (`x11vnc`).
5. Launches the viewer against the BMC and keeps it running.

You then point any VNC client at the container and use the server's console
normally.

Because the viewer is fetched from your own BMC at run time, **no proprietary
ATEN files are stored in this repository.**

## Requirements

- Docker.
- On an Apple Silicon Mac: Docker Desktop with **Rosetta** turned on
  (Settings → General → "Use Rosetta for x86/amd64 emulation"). The image is
  `linux/amd64`; Rosetta makes it usable instead of slow.
- Network reachability from the container to the BMC.
- A VNC client. macOS has one built in (`open vnc://...`).

## Quick start

```bash
BMC_HOST=10.0.0.65 BMC_USER=ADMIN BMC_PASS=ADMIN VNC_PASS=secret ./run.sh
```

`run.sh` builds the image, starts the container, publishes the VNC port on
`127.0.0.1:5901`, and on macOS opens Screen Sharing to it. Enter the VNC
password you set, and the server's console appears.

Manual equivalent:

```bash
docker build --platform linux/amd64 -t supermicro-ikvm .

docker run -d --name ikvm --platform linux/amd64 \
  -p 127.0.0.1:5901:5901 \
  -e BMC_HOST=10.0.0.65 -e BMC_USER=ADMIN -e BMC_PASS=ADMIN \
  -e VNC_PASS=secret \
  supermicro-ikvm

open vnc://localhost:5901        # macOS; or use any VNC client
docker logs -f ikvm              # watch progress / troubleshoot
docker rm -f ikvm                # stop
```

## Configuration

| Variable   | Default    | Meaning                                             |
|------------|------------|-----------------------------------------------------|
| `BMC_HOST` | (required) | BMC IP or hostname                                  |
| `BMC_USER` | `ADMIN`    | BMC user                                            |
| `BMC_PASS` | `ADMIN`    | BMC password                                        |
| `VNC_PORT` | `5901`     | host port (`run.sh`); container always serves 5901  |
| `VNC_PASS` | `changeme` | VNC password for the exported display               |
| `GEOM`     | `1280x1024x24` | virtual display size                            |

## Using the console

- **Connect:** `vnc://localhost:5901` with your `VNC_PASS`.
- **Keyboard focus:** click once inside the video area before you type. The
  viewer grabs the keyboard when the mouse is over the video.
- **Function keys (F2, F11, DEL, Ctrl+Alt+Del, arrows):** use the viewer's own
  on-screen keyboard — menu **Virtual Media → Virtual Keyboard**. A client or
  window manager can swallow real F-keys, but the on-screen keyboard sends them
  straight through the viewer. This matters for BIOS setup (DEL) and the boot
  menu (F11, or F3 on a remote keyboard).
- **"Resolution not supported" popups:** the viewer shows these when the
  server changes video mode during POST. They are harmless; click OK.

## How it works (files)

- `Dockerfile` — `linux/amd64` Debian + Java 8 + X/VNC + the viewer's runtime
  dependencies.
- `entrypoint.sh` — logs in to the BMC, downloads and unpacks the viewer,
  starts the display and VNC, and runs the viewer in a relaunch loop.
- `run.sh` — build + run + open a viewer, for convenience.

## Scope and limitations

- Built and used against a **Supermicro X8DTN+-F** (ATEN / WPCM450 BMC, iKVM
  viewer 1.69). Other ATEN-based Supermicro boards of that era should work,
  since the viewer and its JNLP layout are shared; versions are read from the
  board at run time.
- The BMC login uses plain **HTTP** — that is how these old boards work. Keep
  the BMC on a trusted management network.
- Set a real `VNC_PASS`. The display is published on `127.0.0.1` only by
  default; do not expose it on a public interface.
- The proprietary viewer is **not redistributed** here. It is pulled from the
  BMC you point the container at, which you are licensed to use with that board.

## Troubleshooting

- `docker logs -f ikvm` shows each step (login, download, launch).
- Blank or "No Signal": the server has no video yet (powered off, or early in
  POST). The console reflects the real screen.
- Slow or choppy on Apple Silicon: confirm Docker Desktop's Rosetta option is on.
- Login fails: check `BMC_HOST` reachability from the container
  (`docker exec ikvm curl -s -o /dev/null -w '%{http_code}' http://$BMC_HOST/`).
