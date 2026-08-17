# Config guide for user agents

**Audience:** coding agents / automation assisting a human with this repo.  
**Goal:** start the stack, point it at the user’s Remotive broker, drive CPD state changes, and debug without guessing.

Human-facing overview: [`README.md`](README.md). This file is the **operational playbook**.

---

## 1. System in one paragraph

Two Docker containers:

1. **`cpd-cuttlefish`** — AAOS Cuttlefish guest with app `com.emtek.cpd` (fullscreen WebView HMI). UI at **https://localhost:8443**.
2. **`cpd-bridge`** — Python service: subscribe to Remotive signals → map to CPD state → `adb` Intent/`broadcast` into the guest.

```
Remotive broker (host, often 127.0.0.1:50130)
        │  namespace + Door_Cmd / Door_Target
        ▼
   cpd-bridge  (network_mode: host)
        │  adb → 127.0.0.1:6520  user 10
        ▼
   cpd-cuttlefish  →  WebView CPD.setState(0|1|2)
```

**Do not** invent a third control path (VHAL, HTTP into the app) unless the user asks. The supported path is Remotive → bridge → ADB → app.

---

## 2. Preconditions (check before changing code)

Run these and use real values from the user’s machine:

```bash
# Repo root
pwd   # expect …/remotive_cuttlefish_cpd or AAOS_Cuttlefish

# Docker + KVM
docker info >/dev/null && ls -l /dev/kvm

# Remotive topology broker already up? (example psw-bench01)
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -iE 'broker|topology|remotive' || true
ss -ltn | grep -E '50130|50051' || true

# remotive CLI (optional but needed for restbus inject)
command -v remotive && remotive --version
```

If no broker is listening, **tell the user** to start their Topology/bench first. This compose does **not** start Remotive.

---

## 3. Files you may edit

| Path | When to edit | Notes |
|------|----------------|-------|
| [`bridge/config.yaml`](bridge/config.yaml) | Different broker URL, namespace, signal names, ADB serial | Primary config; bind-mounted into bridge |
| [`.env`](.env) (from [`.env.example`](.env.example)) | Image tags, compose env overrides | Optional |
| [`docker-compose.yml`](docker-compose.yml) | Ports, resources, image names | Prefer env vars over hardcoding |
| [`bridge/main.py`](bridge/main.py) | Logic bugs only | Mapping is also in YAML `mapping.rules` |
| App under `app/ChildPresentDetection/` | UI / Intent handling | Requires `./scripts/deploy-apk.sh` after change |

**Do not commit** secrets. `api_key` in config is for cloud brokers; leave empty for local.

---

## 4. Configure for the user’s Remotive instance

### 4.1 Discover broker URL and signals

```bash
# List signals (adjust URL to the host-mapped gRPC port)
remotive broker signals list --url http://127.0.0.1:50130 | head -c 5000

# Or namespaces only
remotive broker signals namespaces --url http://127.0.0.1:50130
```

Find:

- **broker_url** — e.g. `http://127.0.0.1:50130` (must be reachable from the **host** network; bridge uses `network_mode: host`).
- **namespace** — e.g. `topology-BodyCAN` (not `DoorECU-BodyCAN` unless that is what the user injects on).
- Exact signal names — this project defaults to:
  - `OpenDoorMsg.Door_Cmd`
  - `OpenDoorMsg.Door_Target`

### 4.2 Edit `bridge/config.yaml`

Minimal template:

```yaml
remotive:
  broker_url: "http://127.0.0.1:50130"    # CHANGE to user's broker
  api_key: ""
  namespace: "topology-BodyCAN"            # CHANGE if needed
  door_cmd_signal: "OpenDoorMsg.Door_Cmd"
  door_target_signal: "OpenDoorMsg.Door_Target"
  on_change: true

cuttlefish:
  adb_serial: "127.0.0.1:6520"             # host port mapped from cuttlefish
  adb_path: "adb"
  package: "com.emtek.cpd"
  activity: "com.emtek.cpd/.MainActivity"
  intent_action: "com.emtek.cpd.SET_STATE"
  reconnect_interval_s: 5
  min_intent_interval_s: 0.3

mapping:
  rules:
    - door_cmd: 1
      door_target: 1
      cpd_state: 1
      sound: true
    - door_cmd: 0
      door_target: 0
      cpd_state: 0
      sound: false
    - door_cmd: 1
      door_target: 0
      cpd_state: 2
      sound: true
```

### 4.3 Env overrides (no file edit)

Compose already forwards:

```bash
export REMOTIVE_BROKER_URL=http://127.0.0.1:50130
export REMOTIVE_NAMESPACE=topology-BodyCAN
export CUTTLEFISH_ADB=127.0.0.1:6520
docker compose up -d bridge --force-recreate
```

Env overrides **broker_url / namespace / adb_serial** only (see `bridge/main.py` `load_config`). Signal names and mapping rules stay in YAML.

### 4.4 After any config change

```bash
docker compose up -d bridge --force-recreate
docker logs -f cpd-bridge   # expect: Broker connected … ADB ready … android_user=10
```

---

## 5. Default CPD mapping (do not change unless asked)

| Door_Cmd | Door_Target | cpd_state | UI | sound |
|---------:|------------:|----------:|----|:-----:|
| 1 | 1 | **1** | Child Detected | true |
| 0 | 0 | **0** | None | false |
| 1 | 0 | **2** | Escalation | true |

Unmatched pairs → keep last state (no Intent).

To change mapping, edit `mapping.rules` in `bridge/config.yaml` and recreate bridge. No APK rebuild needed for mapping-only changes.

---

## 6. Bring the system up

### 6.1 First time on a machine

```bash
cd <repo-root>
./scripts/build-images.sh    # APK + cpd-cuttlefish + cpd-remotive-bridge
./scripts/run-all.sh         # compose up + wait for :8443
```

Or:

```bash
docker compose up -d --build
```

### 6.2 Using CI images (GHCR)

```bash
export CUTTLEFISH_IMAGE=ghcr.io/minhtuan76800310/remotive_cuttlefish_cpd/cpd-cuttlefish:latest
export BRIDGE_IMAGE=ghcr.io/minhtuan76800310/remotive_cuttlefish_cpd/cpd-remotive-bridge:latest
# if private: echo $CR_PAT | docker login ghcr.io -u USER --password-stdin
docker compose pull
docker compose up -d
```

### 6.3 Success criteria

```bash
docker ps --filter name=cpd- --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
# cpd-cuttlefish … healthy (or starting)
# cpd-bridge … Up

curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:8443
# 200 or similar

docker logs --tail 30 cpd-bridge
# Loaded config … ADB ready … android_user=10 … Broker connected …
```

Tell the user to open **https://localhost:8443**, accept self-signed cert, connect WebRTC. First boot can take **several minutes**.

### 6.4 Stop

```bash
docker compose down
```

---

## 7. Drive signals (end-to-end test)

Prefer **restbus** when Studio UI is unavailable. Use the **same** `--url` and namespace as `bridge/config.yaml`.

```bash
URL="${REMOTIVE_BROKER_URL:-http://127.0.0.1:50130}"
NS="${REMOTIVE_NAMESPACE:-topology-BodyCAN}"

# Once per broker session (or after restbus reset)
remotive broker restbus add --url "$URL" \
  --frame "${NS}:OpenDoorMsg" --cycle-time 100 --start

# State 1 — Child Detected + sound
remotive broker restbus update --url "$URL" \
  --signal "${NS}:OpenDoorMsg.Door_Cmd:1" \
  --signal "${NS}:OpenDoorMsg.Door_Target:1"

# State 2 — Escalation + sound
remotive broker restbus update --url "$URL" \
  --signal "${NS}:OpenDoorMsg.Door_Cmd:1" \
  --signal "${NS}:OpenDoorMsg.Door_Target:0"

# State 0 — clear
remotive broker restbus update --url "$URL" \
  --signal "${NS}:OpenDoorMsg.Door_Cmd:0" \
  --signal "${NS}:OpenDoorMsg.Door_Target:0"
```

Helper:

```bash
./scripts/test-remotive-cpd.sh
```

**Important:**

- `restbus update` alone is not enough if the frame was never `add --start`’d (or after `restbus reset`).
- If subscribe shows nothing, try one-shot publish to prove the path:

```bash
remotive broker signals publish --url "$URL" \
  --signal "${NS}:OpenDoorMsg.Door_Cmd:1" \
  --signal "${NS}:OpenDoorMsg.Door_Target:1"
```

---

## 8. Verify the chain (agent checklist)

Work **top-down**. Stop at the first failing layer.

### L1 — Bridge sees Remotive

```bash
docker logs --tail 50 cpd-bridge
```

Expect on signal change:

```text
CPD state=1 sound=True user=10  bc=[Broadcast completed: result=0] …
```

If only “Broker connected” and never `CPD state=`:

- Wrong namespace/signal names
- Restbus not started
- Broker URL wrong / not on localhost (bridge is host-networked)

Quick subscribe probe:

```bash
timeout 5 remotive broker signals subscribe --url http://127.0.0.1:50130 \
  --signal 'topology-BodyCAN:OpenDoorMsg.Door_Cmd' \
  --signal 'topology-BodyCAN:OpenDoorMsg.Door_Target' \
  --no-on-change-only
```

### L2 — ADB reaches guest

```bash
docker exec cpd-cuttlefish /root/bin/adb connect localhost:6520
docker exec cpd-cuttlefish /root/bin/adb -s localhost:6520 get-state
# device

docker exec cpd-cuttlefish /root/bin/adb -s localhost:6520 shell pm path com.emtek.cpd
docker exec cpd-cuttlefish /root/bin/adb -s localhost:6520 shell dumpsys activity activities \
  | grep -E 'topResumedActivity|com.emtek.cpd' | head
```

AAOS often runs the app as **user 10**. Bridge auto-detects; manual commands must use `--user 10` if needed.

### L3 — App applies JS state

```bash
ADB='docker exec cpd-cuttlefish /root/bin/adb -s localhost:6520'
$ADB logcat -c
# trigger a remotive update or:
$ADB shell am broadcast --user 10 -a com.emtek.cpd.SET_STATE \
  -n com.emtek.cpd/.MainActivity --ei state 2 --ez sound true
$ADB logcat -d -s ChildPresentDetection:I | tail -30
```

Expect:

```text
control intent state=2 sound=true pageReady=true
evaluateJavascript state=2 …
JS result="ok state=escalation code=2 set=true"
[web] [CPD] state → escalation …
```

If ActivityManager shows START but **no** `ChildPresentDetection` lines → **stale APK** (no SET_STATE handler). Fix:

```bash
./scripts/deploy-apk.sh
```

### L4 — UI

User watches https://localhost:8443:

| state | What to see |
|------:|-------------|
| 0 | Footer `CPD: NO OCCUPANT`, no overlay |
| 1 | Amber CPD telltale / `CPD: CHILD DETECTED` |
| 2 | Full-screen “Check Rear Seat” escalation |

---

## 9. Manual control (bypass Remotive)

Use when isolating app vs bridge:

```bash
ADB='docker exec cpd-cuttlefish /root/bin/adb -s localhost:6520'
USER=10   # or detect from dumpsys

$ADB shell am broadcast --user $USER -a com.emtek.cpd.SET_STATE \
  -n com.emtek.cpd/.MainActivity --ei state 1 --ez sound true

$ADB shell am start --user $USER -n com.emtek.cpd/.MainActivity \
  -a com.emtek.cpd.SET_STATE --ei state 2 --ez sound true
```

| state | meaning |
|------:|---------|
| 0 or 3 | none |
| 1 | child detected |
| 2 | escalation |

Bridge sends **both** broadcast and start (more reliable on `singleTask` + multi-user).

---

## 10. Common agent tasks

### A. Point at a different broker port

1. Edit `bridge/config.yaml` → `remotive.broker_url` **or** set `REMOTIVE_BROKER_URL`.
2. `docker compose up -d bridge --force-recreate`.
3. Re-run restbus against the **new** URL.

### B. Different signal names

1. Confirm with `remotive broker signals list`.
2. Set `door_cmd_signal` / `door_target_signal` / `namespace` in YAML.
3. Recreate bridge.
4. Update restbus `--frame` / `--signal` strings to match.

### C. Rebuild CPD UI / Intent code

```bash
./scripts/deploy-apk.sh
# rebuilds APK, adb install -r (or uninstall+install on signature mismatch), launches MainActivity
```

### D. Rebuild both images after Dockerfile changes

```bash
./scripts/build-images.sh
docker compose up -d
```

### E. Cuttlefish only (no bridge)

```bash
docker compose up -d cuttlefish
# or: docker compose -f cuttlefish/docker-compose.yml up -d
```

### F. Change guest RAM/CPU

```bash
export CUTTLEFISH_MEMORY_MB=8192 CUTTLEFISH_CPUS=6
docker compose up -d cuttlefish --force-recreate
```

---

## 11. Ports & containers (quick ref)

| Port (host) | Service |
|-------------|---------|
| **8443** | Cuttlefish WebRTC UI |
| **6520** | ADB |
| 1443 | Orchestrator / signaling |
| 9300 | VHAL proxy (optional; not used by CPD bridge) |
| 50130 | Typical Remotive topology broker (external) |

| Name | Image default |
|------|----------------|
| `cpd-cuttlefish` | `cpd-cuttlefish:latest` |
| `cpd-bridge` | `cpd-remotive-bridge:latest` |

Bridge **must** stay on `network_mode: host` if the broker listens on `127.0.0.1` only.

---

## 12. Failure matrix

| Observation | Likely cause | Agent action |
|-------------|--------------|--------------|
| No `cpd-bridge` container | Not started | `docker compose up -d bridge` |
| Bridge: connect refused to broker | Wrong URL / broker down | Fix URL; start topology |
| Bridge: ADB not device | Cuttlefish still booting | Wait; check `docker logs cpd-cuttlefish` |
| Bridge: `CPD state=` but UI frozen | Stale APK | `./scripts/deploy-apk.sh` |
| restbus update OK, subscribe silent | Frame not started / reset | `restbus add --start` again |
| Intent delivered, no logcat tag | Old app without handler | Redeploy APK |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Debug keystore changed | deploy script uninstalls+reinstalls |
| Wrong user | Commands hit user 0 | Use `--user 10` or bridge auto-detect |
| UI old after asset change | App not reinstalled | deploy-apk; force-stop + start |

---

## 13. What not to do

- Do **not** remove `network_mode: host` from bridge without providing a broker address reachable from the Docker bridge network (and open ADB accordingly).
- Do **not** assume host `adb` is installed; prefer `docker exec cpd-cuttlefish /root/bin/adb` or the bridge container’s `adb`.
- Do **not** treat README state codes `1/2/3` in older notes as conflicting: app accepts **0 or 3 = none**, **1 = detected**, **2 = escalation**.
- Do **not** commit `.env` with secrets, large screenshots, or `app/**/build` / `.gradle` (see `.gitignore`).
- Do **not** push Docker images from the agent unless the user asks; CI publishes to GHCR on push to `master`/`main`.

---

## 14. Suggested agent workflow (copy-paste)

```text
1. Confirm broker: ss/docker ps + remotive signals list
2. Align bridge/config.yaml (url, namespace, signal names)
3. ./scripts/run-all.sh  (or compose up if images exist)
4. Wait healthy :8443 + bridge "Broker connected" + "ADB ready"
5. restbus add --start; update 1/1, 1/0, 0/0
6. docker logs cpd-bridge | grep 'CPD state'
7. adb logcat -s ChildPresentDetection:I | grep 'JS result'
8. Ask user to confirm UI on https://localhost:8443
9. If fail: walk L1→L4 in section 8; deploy-apk if L3 broken
```

---

## 15. Key paths

```
bridge/config.yaml          # runtime config (edit + recreate bridge)
bridge/main.py              # subscribe + map + adb
bridge/Dockerfile
cuttlefish/Dockerfile       # AAOS base + baked APK
cuttlefish/init.sh          # boot, install APK, launch CPD
cuttlefish/apks/*.apk
app/ChildPresentDetection/  # Android sources
  app/src/main/assets/index.html   # CPD UI (HTML) — see ui_html_to_cuttlefish_guide.md
docker-compose.yml          # both services
scripts/build-images.sh
scripts/deploy-apk.sh       # after any assets/index.html change
scripts/test-remotive-cpd.sh
ui_html_to_cuttlefish_guide.md
.github/workflows/build-images.yml
```

---

## Related: change the CPD look from HTML

Visual / markup updates are **not** done via Remotive config. Follow:

→ [`ui_html_to_cuttlefish_guide.md`](ui_html_to_cuttlefish_guide.md)

Summary: edit `app/ChildPresentDetection/app/src/main/assets/index.html` (keep `window.CPD`), then `./scripts/deploy-apk.sh`.

---

*End of agent guide. Prefer this file for procedures; prefer README.md for human onboarding.*
