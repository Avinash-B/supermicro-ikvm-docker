#!/bin/bash
# Start a headless X display, fetch the ATEN iKVM viewer from the BMC, run it,
# and export the screen over VNC. Nothing proprietary is baked into the image:
# the exact viewer version is downloaded from the BMC itself at runtime.
set -u

BMC_HOST="${BMC_HOST:?set BMC_HOST to the BMC IP or hostname}"
BMC_USER="${BMC_USER:-ADMIN}"
BMC_PASS="${BMC_PASS:-ADMIN}"
VNC_PORT="${VNC_PORT:-5901}"
VNC_PASS="${VNC_PASS:-changeme}"
GEOM="${GEOM:-1280x1024x24}"
export DISPLAY=:0

IKVM_DIR=/opt/ikvm
NAT_DIR="$IKVM_DIR/natives"
CK=/tmp/bmc_cookies.txt
JNLP=/tmp/ikvm.jnlp

log() { echo "[ikvm] $*"; }

bmc_login() {
  # login.cgi sets an SID cookie; the SID is also embedded in the JNLP below
  curl -s -m 20 -c "$CK" --data "name=${BMC_USER}&pwd=${BMC_PASS}" \
       "http://${BMC_HOST}/cgi/login.cgi" >/dev/null 2>&1
  SID="$(awk '/SID/{print $NF}' "$CK" 2>/dev/null)"
  [ -n "$SID" ]
}

fetch_jnlp() {
  # The JNLP describes the viewer jar, the per-OS native libs, the main class,
  # and the launch arguments (host, session token, KVM port 5900, vmedia 623,
  # company/board ids). We parse it so this works across board/firmware versions.
  curl -s -m 20 -b "$CK" -e "http://${BMC_HOST}/" \
       "http://${BMC_HOST}/cgi/url_redirect.cgi?url_name=sess_${SID}&url_type=jwsk" \
       -o "$JNLP" 2>/dev/null
  grep -q 'application-desc' "$JNLP" 2>/dev/null
}

# Download a jar named <href> at <version> from the BMC. These boards serve
# version-enabled, pack200-compressed jars as  <base>__V<version>.jar.pack.gz .
# Fall back to a plain .jar if that is not present.
dl_jar() {
  local href="$1" ver="$2" out="$3" base
  base="${href%.jar}"
  if curl -sk -f -m 90 -b "$CK" -e "https://${BMC_HOST}/" \
         -o "${out}.pack.gz" "https://${BMC_HOST}/${base}__V${ver}.jar.pack.gz" 2>/dev/null; then
    unpack200 "${out}.pack.gz" "$out" && rm -f "${out}.pack.gz" && return 0
  fi
  curl -sk -f -m 90 -b "$CK" -e "https://${BMC_HOST}/" \
       -o "$out" "https://${BMC_HOST}/${href}" 2>/dev/null
}

download_viewer() {
  local main_line nat_line
  main_line="$(grep '<jar ' "$JNLP" | grep 'main="true"' | head -1)"
  MAIN_HREF="$(echo "$main_line" | sed -n 's/.*href="\([^"]*\)".*/\1/p')"
  MAIN_VER="$(echo  "$main_line" | sed -n 's/.*version="\([^"]*\)".*/\1/p')"
  # prefer the x86_64 Linux native lib (amd64 is listed with the same href)
  nat_line="$(grep 'nativelib' "$JNLP" | grep -i 'linux_x86_64' | head -1)"
  NAT_HREF="$(echo "$nat_line" | sed -n 's/.*href="\([^"]*\)".*/\1/p')"
  NAT_VER="$(echo  "$nat_line" | sed -n 's/.*version="\([^"]*\)".*/\1/p')"

  [ -n "$MAIN_HREF" ] && [ -n "$NAT_HREF" ] || { log "could not parse jar names from JNLP"; return 1; }

  log "downloading viewer $MAIN_HREF ($MAIN_VER) and native $NAT_HREF ($NAT_VER)"
  dl_jar "$MAIN_HREF" "$MAIN_VER" "$IKVM_DIR/iKVM.jar" || { log "viewer jar download failed"; return 1; }
  dl_jar "$NAT_HREF"  "$NAT_VER"  "$IKVM_DIR/native.jar" || { log "native jar download failed"; return 1; }

  rm -rf "$NAT_DIR"; mkdir -p "$NAT_DIR"
  ( cd "$NAT_DIR" && unzip -o -j "$IKVM_DIR/native.jar" '*.so' >/dev/null )
  log "native libs: $(ls "$NAT_DIR" 2>/dev/null | tr '\n' ' ')"
}

start_display() {
  log "starting Xvfb ($GEOM)"
  Xvfb :0 -screen 0 "$GEOM" -ac >/var/log/xvfb.log 2>&1 &
  sleep 2
  # empty keybindings so the window manager does not swallow function keys
  mkdir -p /root/.fluxbox; : > /root/.fluxbox/keys
  fluxbox >/var/log/fluxbox.log 2>&1 &
  sleep 1
  log "starting x11vnc on :${VNC_PORT}"
  x11vnc -display :0 -forever -shared -rfbport "$VNC_PORT" -passwd "$VNC_PASS" \
         -listen 0.0.0.0 -noxdamage -bg -o /var/log/x11vnc.log
  sleep 1
}

launch_viewer() {
  local main_class args
  main_class="$(sed -n 's/.*main-class="\([^"]*\)".*/\1/p' "$JNLP")"
  # host, SID, SID, 5900, 623, companyId, boardId  (verbatim from the JNLP)
  args="$(sed -n 's/.*<argument>\(.*\)<\/argument>.*/\1/p' "$JNLP" | tr '\n' ' ')"
  log "launching $main_class $args"
  cd "$IKVM_DIR"
  java -Djava.library.path="$NAT_DIR" -cp "$IKVM_DIR/iKVM.jar" $main_class $args \
       >>/var/log/viewer.log 2>&1
}

# --- main ---------------------------------------------------------------
start_display

for t in 1 2 3 4 5; do
  if bmc_login && fetch_jnlp; then break; fi
  log "BMC login/JNLP attempt $t failed; retrying in 4s"; sleep 4
done
[ -n "${SID:-}" ] || { log "FATAL: could not log in to BMC ${BMC_HOST}"; sleep 3600; exit 1; }

if [ ! -f "$IKVM_DIR/iKVM.jar" ]; then
  download_viewer || { log "FATAL: could not download the viewer from the BMC"; sleep 3600; exit 1; }
fi

log "ready. Connect a VNC client to this container's port ${VNC_PORT} (password: ${VNC_PASS})."

# Relaunch loop: a fresh session token is needed each time the viewer starts,
# so re-login and re-read the JNLP before every launch.
while true; do
  bmc_login && fetch_jnlp && launch_viewer
  log "viewer exited; restarting in 3s"
  sleep 3
done
