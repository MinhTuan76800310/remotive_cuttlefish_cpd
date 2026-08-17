#!/usr/bin/env bash
# Cycle OpenDoorMsg via restbus and show bridge log reactions.
set -euo pipefail

URL="${REMOTIVE_BROKER_URL:-http://127.0.0.1:50130}"
NS="${REMOTIVE_NAMESPACE:-topology-BodyCAN}"
FRAME="${NS}:OpenDoorMsg"
CMD="${NS}:OpenDoorMsg.Door_Cmd"
TGT="${NS}:OpenDoorMsg.Door_Target"

echo ">> restbus reset/add/start $FRAME on $URL"
remotive broker restbus reset --url "$URL" --namespace "$NS" 2>/dev/null || true
remotive broker restbus add --url "$URL" --frame "$FRAME" --cycle-time 100 --start || true

set_pair() {
  local cmd="$1" tgt="$2" label="$3"
  echo
  echo ">> $label  Door_Cmd=$cmd Door_Target=$tgt"
  remotive broker restbus update --url "$URL" \
    --signal "${CMD}:${cmd}" \
    --signal "${TGT}:${tgt}"
  sleep 2
  docker logs --tail 8 cpd-bridge 2>&1 || true
}

set_pair 1 1 "CPD state 1 + sound (child detected)"
set_pair 1 0 "CPD state 2 + sound (escalation)"
set_pair 0 0 "CPD state 0 (none)"
set_pair 1 1 "CPD state 1 + sound again"

echo
echo "Done. Watch UI at https://localhost:8443 and: docker logs -f cpd-bridge"
