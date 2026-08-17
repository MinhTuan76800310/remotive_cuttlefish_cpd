#!/usr/bin/env bash
# Boot Cuttlefish (AAOS), install APKs from /root/apks, launch Child Present Detection.
set -euo pipefail

ulimit -n 4096

# Existing orchestrator startup script (from cuttlefish-orchestration image / remotivelabs image)
if [[ -x ./run_services.sh ]]; then
  ./run_services.sh &
elif [[ -x /root/run_services.sh ]]; then
  /root/run_services.sh &
fi

# Wait for orchestrator (if present)
for _ in $(seq 1 60); do
  if nc -z localhost 2081 2>/dev/null || nc -z 127.0.0.1 2081 2>/dev/null; then
    break
  fi
  sleep 1
done
sleep 3

mkdir -p state/images
# Prefer pre-staged images under /root; fall back to cwd artifacts from the image
shopt -s nullglob
for f in bootloader *.img; do
  [[ -e "$f" ]] || continue
  cp -n "$f" state/images/ 2>/dev/null || true
done
shopt -u nullglob

ADB_BIN=""
if [[ -x ./bin/adb ]]; then
  ADB_BIN=./bin/adb
elif [[ -x /root/bin/adb ]]; then
  ADB_BIN=/root/bin/adb
elif command -v adb >/dev/null 2>&1; then
  ADB_BIN=adb
fi

LAUNCH_CVD=""
if [[ -x ./bin/launch_cvd ]]; then
  LAUNCH_CVD=./bin/launch_cvd
elif [[ -x /root/bin/launch_cvd ]]; then
  LAUNCH_CVD=/root/bin/launch_cvd
fi

STOP_CVD=""
if [[ -x ./bin/stop_cvd ]]; then
  STOP_CVD=./bin/stop_cvd
elif [[ -x /root/bin/stop_cvd ]]; then
  STOP_CVD=/root/bin/stop_cvd
fi

if [[ -n "$LAUNCH_CVD" ]]; then
  "$LAUNCH_CVD" --daemon \
    --vhost_user_vsock=false \
    --instance_dir=/root/state/ \
    --system_image_dir=/root/state/images \
    --gpu_mode="${CUTTLEFISH_GPU_MODE:-auto}" \
    --memory_mb="${CUTTLEFISH_MEMORY_MB:-4096}" \
    --cpus="${CUTTLEFISH_CPUS:-4}" \
    --guest_enforce_security=false \
    --enable_vhal_proxy_server \
    --display="${CUTTLEFISH_DISPLAY_MAIN:-width=1400,height=800,dpi=160,refresh_rate_hz=30}" \
    --report_anonymous_usage_stats=n
  sleep 3
fi

if [[ -n "$ADB_BIN" ]]; then
  "$ADB_BIN" connect localhost:6520 || true
  sleep 2
  # Prefer a single serial to avoid "more than one device"
  ADB=("$ADB_BIN" -s localhost:6520)
  "${ADB[@]}" wait-for-device || true
  "${ADB[@]}" root || true
  sleep 2
  "${ADB[@]}" wait-for-device || true
  # Wait until package manager is up
  for _ in $(seq 1 60); do
    if "${ADB[@]}" shell pm path android >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  # Install optional APKs (any .apk under /root/apks)
  shopt -s nullglob
  for apk in /root/apks/*.apk apks/*.apk; do
    echo "Installing $apk ..."
    "${ADB[@]}" install -r "$apk" || "${ADB[@]}" install "$apk" || true
  done
  shopt -u nullglob

  # Network / driving UX helpers (best-effort on AAOS images)
  "${ADB[@]}" shell svc wifi enable 2>/dev/null || true
  "${ADB[@]}" shell cmd wifi connect-network VirtWifi open 2>/dev/null || true
  "${ADB[@]}" shell ip link set mtu 1400 dev wlan0 2>/dev/null || true

  if "${ADB[@]}" shell service list 2>/dev/null | grep -q car_service; then
    "${ADB[@]}" shell cmd car_service enable-uxr false 2>/dev/null || true
  fi

  # Launch Child Present Detection if installed
  PKG="${CPD_PACKAGE:-com.emtek.cpd}"
  ACTIVITY="${CPD_ACTIVITY:-.MainActivity}"
  if "${ADB[@]}" shell pm path "$PKG" >/dev/null 2>&1; then
    echo "Launching ${PKG}/${ACTIVITY} ..."
    "${ADB[@]}" shell am start -n "${PKG}/${ACTIVITY}" || true
    sleep 5
    "${ADB[@]}" shell am start -n "${PKG}/${ACTIVITY}" || true
  else
    echo "WARNING: package $PKG not installed; skip auto-launch"
  fi
fi

# Masquerade guest traffic if eth0 exists
if command -v iptables >/dev/null 2>&1; then
  iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null \
    || true
fi

# Expose VHAL proxy if present
if command -v socat >/dev/null 2>&1; then
  socat TCP-LISTEN:9300,fork,reuseaddr,bind=0.0.0.0 TCP:192.168.98.1:9300 2>/dev/null &
fi

echo "Cuttlefish is started. Open https://localhost:8443 for the WebRTC console."

sleep infinity &
blocked_pid=$!

stop_cuttlefish() {
  if [[ -n "$ADB_BIN" ]]; then
    "$ADB_BIN" reboot 2>/dev/null || true
  fi
  if [[ -n "$STOP_CVD" ]]; then
    "$STOP_CVD" 2>/dev/null || true
  fi
  kill -TERM "$blocked_pid" 2>/dev/null || true
  exit 0
}

trap stop_cuttlefish INT TERM
wait "$blocked_pid"
stop_cuttlefish
