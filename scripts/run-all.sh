#!/usr/bin/env bash
# Build images if needed, start cuttlefish + remotive bridge (2 containers).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="$ROOT/cuttlefish/apks/ChildPresentDetection.apk"
CF_IMAGE="${CUTTLEFISH_IMAGE:-cpd-cuttlefish:latest}"
BR_IMAGE="${BRIDGE_IMAGE:-cpd-remotive-bridge:latest}"

chmod +x "$ROOT/scripts/"*.sh "$ROOT/cuttlefish/init.sh" 2>/dev/null || true

need_build=0
if [[ ! -f "$APK" ]]; then
  need_build=1
fi
if ! docker image inspect "$CF_IMAGE" >/dev/null 2>&1; then
  need_build=1
fi
if ! docker image inspect "$BR_IMAGE" >/dev/null 2>&1; then
  need_build=1
fi

if [[ "$need_build" -eq 1 ]]; then
  echo ">> Building images (APK + cuttlefish + bridge)..."
  "$ROOT/scripts/build-images.sh"
fi

cd "$ROOT"
echo ">> Starting cuttlefish + bridge ..."
docker compose up -d --build

echo ">> Waiting for WebRTC console on https://localhost:8443 ..."
ready=0
for i in $(seq 1 120); do
  if curl -sk --max-time 2 "https://localhost:8443" -o /dev/null; then
    ready=1
    break
  fi
  if curl -s --max-time 2 "http://localhost:8443" -o /dev/null; then
    ready=1
    break
  fi
  sleep 5
  if (( i % 6 == 0 )); then
    echo "   ... still booting ($((i*5))s)"
    docker compose ps
  fi
done

echo
echo "============================================================"
echo " Containers:"
docker compose ps
echo
echo " CPD UI:     https://localhost:8443"
echo " ADB:        adb connect localhost:6520"
echo " Bridge log: docker logs -f cpd-bridge"
echo " Config:     bridge/config.yaml"
echo
echo " Drive CPD from Remotive (restbus):"
echo "   remotive broker restbus add --url http://127.0.0.1:50130 \\"
echo "     --frame 'topology-BodyCAN:OpenDoorMsg' --cycle-time 100 --start"
echo "   # state 1 + sound  (Door_Cmd=1, Door_Target=1):"
echo "   remotive broker restbus update --url http://127.0.0.1:50130 \\"
echo "     --signal 'topology-BodyCAN:OpenDoorMsg.Door_Cmd:1' \\"
echo "     --signal 'topology-BodyCAN:OpenDoorMsg.Door_Target:1'"
echo "   # state 2 + sound  (Door_Cmd=1, Door_Target=0):"
echo "   remotive broker restbus update --url http://127.0.0.1:50130 \\"
echo "     --signal 'topology-BodyCAN:OpenDoorMsg.Door_Cmd:1' \\"
echo "     --signal 'topology-BodyCAN:OpenDoorMsg.Door_Target:0'"
echo "   # state 0           (Door_Cmd=0, Door_Target=0):"
echo "   remotive broker restbus update --url http://127.0.0.1:50130 \\"
echo "     --signal 'topology-BodyCAN:OpenDoorMsg.Door_Cmd:0' \\"
echo "     --signal 'topology-BodyCAN:OpenDoorMsg.Door_Target:0'"
echo "============================================================"

if [[ "$ready" -ne 1 ]]; then
  echo "WARNING: port 8443 not responding yet. Check: docker logs cpd-cuttlefish"
  exit 1
fi
