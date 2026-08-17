#!/usr/bin/env bash
# Build Child Present Detection debug APK (uses Docker Android SDK if local SDK missing).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app/ChildPresentDetection"
OUT_DIR="$ROOT/cuttlefish/apks"
APK_NAME="ChildPresentDetection.apk"
mkdir -p "$OUT_DIR"

build_local() {
  (
    cd "$APP_DIR"
    chmod +x ./gradlew
    ./gradlew --no-daemon clean assembleDebug
  )
}

build_docker() {
  echo ">> No local ANDROID_HOME — building APK inside Docker (mingc/android-build-box)..."
  docker run --rm \
    -v "$APP_DIR":/project \
    -w /project \
    mingc/android-build-box:latest \
    bash -lc 'yes | sdkmanager --licenses >/dev/null 2>&1 || true; ./gradlew --no-daemon clean assembleDebug'
}

if [[ -n "${ANDROID_HOME:-}" && -d "${ANDROID_HOME}/platforms" ]] || [[ -n "${ANDROID_SDK_ROOT:-}" && -d "${ANDROID_SDK_ROOT}/platforms" ]]; then
  echo ">> Building with local Android SDK..."
  build_local
else
  build_docker
fi

SRC_APK="$APP_DIR/app/build/outputs/apk/debug/app-debug.apk"
cp -f "$SRC_APK" "$OUT_DIR/$APK_NAME"

# Ensure a single classes.dex with valid R+ packaging (uncompressed aligned resources.arsc)
echo ">> Ensuring single-dex + aligned resources.arsc..."
docker run --rm -v "$OUT_DIR":/apks mingc/android-build-box:latest bash -lc '
set -e
cd /tmp && rm -rf s m out && mkdir s m out && cd s
unzip -qo /apks/ChildPresentDetection.apk
if [[ -f classes2.dex ]]; then
  D8=$(ls /opt/android-sdk/build-tools/*/d8 | tail -1)
  $D8 --min-api 28 --output /tmp/m classes.dex classes2.dex
  cp /tmp/m/classes.dex ./classes.dex
  rm -f classes2.dex classes3.dex
fi
rm -rf META-INF
# Build APK with resources.arsc STORED (method 0) — required for targetSdk >= 30
cd /tmp/out
cp /tmp/s/AndroidManifest.xml .
cp /tmp/s/classes.dex .
cp /tmp/s/resources.arsc .
cp -a /tmp/s/assets .
# compressed entries
zip -q -X cpd-unsigned.apk AndroidManifest.xml classes.dex
zip -q -X -r cpd-unsigned.apk assets
# uncompressed resources.arsc
zip -q -X -0 cpd-unsigned.apk resources.arsc
KEYSTORE=/tmp/debug.keystore
keytool -genkeypair -keystore "$KEYSTORE" -storepass android -alias androiddebugkey \
  -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1 || true
APKSIGNER=$(ls /opt/android-sdk/build-tools/*/apksigner | tail -1)
ZIPALIGN=$(ls /opt/android-sdk/build-tools/*/zipalign | tail -1)
$ZIPALIGN -f -p 4 cpd-unsigned.apk cpd-aligned.apk
$APKSIGNER sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
  --out /apks/ChildPresentDetection.apk cpd-aligned.apk
rm -f /apks/ChildPresentDetection.apk.idsig
# verify packaging
unzip -lv /apks/ChildPresentDetection.apk | grep -E "resources.arsc|classes.dex|Name"
$APKSIGNER verify --verbose /apks/ChildPresentDetection.apk | head -20 || true
'
echo ">> APK: $OUT_DIR/$APK_NAME"
ls -lh "$OUT_DIR/$APK_NAME"
