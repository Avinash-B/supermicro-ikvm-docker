# AGENTS.md

Guidance for an AI agent that drives a Supermicro / ATEN iKVM console through
this container, with no human at the keyboard. It records the quirks that are
easy to get wrong.

## What you get

A running container (see `README.md`) that renders the server's real console on
a virtual X display (`:0`) and exports it over VNC. You interact with the
display from inside the container with `xdotool` and `imagemagick`, both already
installed. You do not need a VNC client to drive it; use the display directly.

## See the screen

```bash
docker exec ikvm bash -c 'DISPLAY=:0 import -window root /tmp/s.png'
docker cp ikvm:/tmp/s.png /tmp/s.png     # then open/read /tmp/s.png
```

Read the window title for quick state without a screenshot:

```bash
docker exec ikvm bash -c 'DISPLAY=:0 xdotool search --name "iKVM Viewer" getwindowname %@ | tail -1'
```

The title shows the live resolution/FPS, "No Signal" (server off or early POST),
or "Video Only" (keyboard/mouse not attached to this session).

## Send keys — two paths, and when to use each

There are two input paths, and the difference is the single biggest source of
wasted effort.

1. **Host synthetic keys (`xdotool key`/`type`).** These reach the server
   **only after you click once inside the video to grab keyboard focus**, and
   only for ordinary keys. Use this for typing text and arrows on a stable
   screen (BIOS setup, the installer, a shell).

   ```bash
   docker exec ikvm bash -c '
     export DISPLAY=:0
     WID=$(xdotool search --name "iKVM Viewer" | tail -1)
     xdotool windowactivate --sync $WID
     xdotool mousemove 640 500 click 1      # click into the video = focus
     sleep 1
     xdotool type --delay 120 "ls"; xdotool key Return'
   ```

2. **The viewer's on-screen keyboard.** Open **Virtual Media → Virtual
   Keyboard**. Clicking its keys sends them through the viewer's own channel,
   independent of X focus and of the window manager. **Use it for function and
   special keys** — `F2`, `F11`, `DEL`, arrows, `Ctrl+Alt+Del` (click `ctrl`,
   `alt`, `del` in sequence; modifiers are sticky). Synthetic `F`-keys sent with
   `xdotool` are frequently swallowed and will silently do nothing on the server.

Rule of thumb: text and arrows on a stable screen → path 1. Anything that must
"just work" (BIOS/boot keys, modifiers) → path 2.

## Quirks that will bite you

- **Focus popups from fluxbox.** The window manager is started with empty
  keybindings so it cannot grab function keys. Do not add keybindings.
- **"Resolution not supported" dialogs.** The viewer pops a modal dialog when
  the server changes video mode (during POST). It steals focus, so your next
  key can land in the dialog instead of the console. Dismiss it first
  (`xdotool key Return`, or click its OK), then send your key.
- **Boot-menu timing is not solvable blindly.** The BIOS boot-device popup and a
  preseed USB's boot menu can auto-advance in under a second. Timed key-spam
  from an agent usually misses them. Prefer a deterministic route: enter BIOS
  Setup (hold `DEL` via the on-screen keyboard during POST, which the firmware
  buffers) and set the boot order there, rather than racing a popup.
- **"Video Only" in the title** means the server granted no keyboard/mouse to
  this session. Re-attach with **Options → Keyboard Mouse Hotplug**, then retry.

## Power and boot control over HTTP

The BMC's web CGI works even when IPMI-over-LAN is disabled. Reuse the cookie
the entrypoint already created (`/tmp/bmc_cookies.txt`) so you do not open
extra sessions (these boards cap concurrent sessions):

```bash
docker exec ikvm bash -c '
  curl -s -b /tmp/bmc_cookies.txt -e "http://$BMC_HOST/" \
       --data "POWER_INFO.XML=(0,0)" http://$BMC_HOST/cgi/ipmi.cgi'   # status
```

`POWER_INFO.XML=(1,N)` on `/cgi/ipmi.cgi` controls power:
`N=0` off, `1` on, `2` cycle, `3` reset, `5` graceful shutdown.
`BMCReset.cgi` resets the BMC itself (clears stuck sessions; does not touch host
power).

Power actions reboot or power the host. Confirm with the user before using them
on a server that may be doing real work.

## Patience with POST

This hardware takes 60-90 seconds from power-on to video (memory training with
large RAM). "No Signal" for a minute is normal; do not assume a hang.

## Do not commit the viewer

`iKVM.jar` and the native libraries are proprietary and are downloaded from the
BMC at run time. They are in `.gitignore`. Keep them out of the repository.
