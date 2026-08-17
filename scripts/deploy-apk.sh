#!/usr/bin/env bash
# Rebuild APK and (re)install + launch on a running Cuttlefish (adb :6520).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERIAL="${ADB_SERIAL:-localhost:6520}"
PKG="com.emtek.cpd"
APK_HOST="$ROOT/cuttlefish/apks/ChildPresentDetection.apk"
APK_IN_CONTAINER="/root/apks/ChildPresentDetection.apk"

"$ROOT/scripts/build-apk.sh"

# Prefer in-container adb: APK is already bind-mounted at /root/apks
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'cpd-cuttlefish'; then
  ADB=(docker exec cpd-cuttlefish /root/bin/adb)
  APK_PATH="$APK_IN_CONTAINER"
elif command -v adb >/dev/null 2>&1; then
  ADB=(adb)
  APK_PATH="$APK_HOST"
else
  echo "No running cpd-cuttlefish container and no host adb."
  exit 1
fi

"${ADB[@]}" connect "$SERIAL" >/dev/null || true
"${ADB[@]}" -s "$SERIAL" wait-for-device
if ! "${ADB[@]}" -s "$SERIAL" install -r "$APK_PATH"; then
  echo ">> install -r failed (likely signature change) — uninstalling and reinstalling..."
  "${ADB[@]}" -s "$SERIAL" uninstall "$PKG" || true
  "${ADB[@]}" -s "$SERIAL" install "$APK_PATH"
fi
"${ADB[@]}" -s "$SERIAL" shell am force-stop com.google.android.car.kitchensink 2>/dev/null || true
"${ADB[@]}" -s "$SERIAL" shell am force-stop "$PKG" 2>/dev/null || true
"${ADB[@]}" -s "$SERIAL" shell am start -n "$PKG/.MainActivity"
echo ">> Launched $PKG on $SERIAL — open https://localhost:8443"
