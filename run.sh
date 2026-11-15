#!/usr/bin/env bash
# Build the image (if needed), start the container, and open a VNC viewer.
#
# Usage:
#   BMC_HOST=10.0.0.65 BMC_USER=ADMIN BMC_PASS=ADMIN ./run.sh
#
# Optional env:
#   VNC_PORT (host port, default 5901)   VNC_PASS (default changeme)
#   IMAGE (default supermicro-ikvm)      NAME (container name, default ikvm)
set -euo pipefail

: "${BMC_HOST:?set BMC_HOST to your BMC IP, e.g. BMC_HOST=10.0.0.65 ./run.sh}"
BMC_USER="${BMC_USER:-ADMIN}"
BMC_PASS="${BMC_PASS:-ADMIN}"
VNC_PORT="${VNC_PORT:-5901}"
VNC_PASS="${VNC_PASS:-changeme}"
IMAGE="${IMAGE:-supermicro-ikvm}"
NAME="${NAME:-ikvm}"

cd "$(dirname "$0")"

echo ">> building ${IMAGE} (linux/amd64)"
docker build --platform linux/amd64 -t "${IMAGE}" .

echo ">> (re)starting container ${NAME}"
docker rm -f "${NAME}" >/dev/null 2>&1 || true
docker run -d --platform linux/amd64 --name "${NAME}" \
  -p "127.0.0.1:${VNC_PORT}:5901" \
  -e BMC_HOST="${BMC_HOST}" -e BMC_USER="${BMC_USER}" -e BMC_PASS="${BMC_PASS}" \
  -e VNC_PASS="${VNC_PASS}" \
  "${IMAGE}" >/dev/null

echo ">> waiting for the viewer to come up (downloads from the BMC, slow under emulation)"
sleep 20
docker logs --tail 20 "${NAME}" || true

URL="vnc://localhost:${VNC_PORT}"
echo ">> connect your VNC client to ${URL}  (password: ${VNC_PASS})"
if [[ "$(uname)" == "Darwin" ]]; then
  open "${URL}" || true   # macOS Screen Sharing
fi
echo ">> logs:   docker logs -f ${NAME}"
echo ">> stop:   docker rm -f ${NAME}"
