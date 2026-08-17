#!/usr/bin/env bash
# Build both product images:
#   1) cpd-cuttlefish:latest     — AAOS Cuttlefish + CPD APK baked in
#   2) cpd-remotive-bridge:latest — Remotive → CPD bridge
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CUTTLEFISH_BASE_IMAGE="${CUTTLEFISH_BASE_IMAGE:-remotivelabs/remotivelabs-cuttlefish:15.0.0-4}"
CUTTLEFISH_IMAGE="${CUTTLEFISH_IMAGE:-cpd-cuttlefish:latest}"
BRIDGE_IMAGE="${BRIDGE_IMAGE:-cpd-remotive-bridge:latest}"
APK="$ROOT/cuttlefish/apks/ChildPresentDetection.apk"

echo "==> Building CPD APK"
"$ROOT/scripts/build-apk.sh"

if [[ ! -f "$APK" ]]; then
  echo "ERROR: APK missing after build: $APK" >&2
  exit 1
fi

echo "==> Building $CUTTLEFISH_IMAGE (base=$CUTTLEFISH_BASE_IMAGE)"
docker build \
  --build-arg "BASE_IMAGE=$CUTTLEFISH_BASE_IMAGE" \
  -t "$CUTTLEFISH_IMAGE" \
  -f cuttlefish/Dockerfile \
  .

echo "==> Building $BRIDGE_IMAGE"
docker build \
  -t "$BRIDGE_IMAGE" \
  -f bridge/Dockerfile \
  bridge

echo
echo "Built images:"
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' \
  | grep -E "REPOSITORY|cpd-cuttlefish|cpd-remotive-bridge" || true
echo
echo "Run:  docker compose up -d"
echo "  or: ./scripts/run-all.sh"
