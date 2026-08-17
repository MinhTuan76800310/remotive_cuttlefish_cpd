#!/usr/bin/env bash
# Compatibility wrapper — starts cuttlefish + bridge (same as run-all.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/scripts/run-all.sh"
