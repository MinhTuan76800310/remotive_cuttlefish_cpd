# Child Present Detection on AAOS Cuttlefish + RemotiveLabs bridge

Run an **Android Automotive (Cuttlefish)** guest with a **Child Present Detection (CPD)** cabin-safety HMI, driven live by **RemotiveLabs Topology** CAN signals.

| What | Where |
|------|--------|
| CPD UI (WebRTC) | **https://localhost:8443** |
| ADB | `localhost:6520` |
| Bridge config | [`bridge/config.yaml`](bridge/config.yaml) |
| Compose (2 containers) | [`docker-compose.yml`](docker-compose.yml) |

---

## Architecture

```
Remotive Topology broker  (e.g. :50130)
        │  OpenDoorMsg.Door_Cmd / OpenDoorMsg.Door_Target
        ▼
   cpd-bridge  ── adb :6520 ──►  cpd-cuttlefish
   (container)                   (AAOS + com.emtek.cpd WebView HMI)
```

| Container | Image | Role |
|-----------|--------|------|
| `cpd-cuttlefish` | `cpd-cuttlefish` | AAOS Cuttlefish guest + CPD app baked in |
| `cpd-bridge` | `cpd-remotive-bridge` | Subscribe Remotive → ADB `SET_STATE` intent |

Bridge uses **`network_mode: host`** so it can reach:

- Remotive broker bound on host `127.0.0.1:50130`
- Cuttlefish ADB published on host `:6520`

---

## Signal → CPD mapping (hardcoded)

Signals (psw-bench01 topology):

- Namespace: `topology-BodyCAN`
- `OpenDoorMsg.Door_Cmd`
- `OpenDoorMsg.Door_Target`

| `Door_Cmd` | `Door_Target` | CPD state | UI | Sound |
|-----------:|--------------:|----------:|----|:-----:|
| **1** | **1** | **1** | Child Detected (amber telltale) | yes |
| **0** | **0** | **0** | None / idle | no |
| **1** | **0** | **2** | Escalation (“Check Rear Seat”) | yes |

Other combinations keep the last applied state.

---

## Prerequisites

- **Docker** with KVM (`/dev/kvm`, user in `kvm` / `docker` groups)
- ~8 GB free RAM for the guest (compose default: 4 GB)
- **RemotiveLabs Topology** already running (broker reachable, e.g. `http://127.0.0.1:50130`)
- Host `remotive` CLI (optional, for restbus inject / test)

Base AAOS image: `remotivelabs/remotivelabs-cuttlefish:15.0.0-4` (pulled on first build).

---

## Quick start (local)

```bash
git clone https://github.com/MinhTuan76800310/remotive_cuttlefish_cpd.git
cd remotive_cuttlefish_cpd

# 1) Build APK + both Docker images
./scripts/build-images.sh

# 2) Start cuttlefish + bridge
./scripts/run-all.sh
# equivalent: docker compose up -d
```

Open **https://localhost:8443**, accept the self-signed certificate, connect to the device display. CPD launches automatically after boot (first boot can take several minutes).

### Stop

```bash
docker compose down
```

### Rebuild / relaunch CPD app only (guest already running)

```bash
./scripts/deploy-apk.sh
```

---

## Configure the bridge

Edit [`bridge/config.yaml`](bridge/config.yaml) (bind-mounted into the bridge):

```yaml
remotive:
  broker_url: "http://127.0.0.1:50130"   # topology broker gRPC URL
  namespace: "topology-BodyCAN"
  door_cmd_signal: "OpenDoorMsg.Door_Cmd"
  door_target_signal: "OpenDoorMsg.Door_Target"
  on_change: true

cuttlefish:
  adb_serial: "127.0.0.1:6520"
  package: "com.emtek.cpd"
  activity: "com.emtek.cpd/.MainActivity"
  intent_action: "com.emtek.cpd.SET_STATE"
```

Environment overrides (also in [`.env.example`](.env.example)):

| Variable | Default | Meaning |
|----------|---------|---------|
| `REMOTIVE_BROKER_URL` | `http://127.0.0.1:50130` | Broker URL |
| `REMOTIVE_NAMESPACE` | `topology-BodyCAN` | CAN namespace |
| `CUTTLEFISH_ADB` | `127.0.0.1:6520` | ADB serial for the guest |
| `CUTTLEFISH_IMAGE` | `cpd-cuttlefish:latest` | Cuttlefish image tag |
| `BRIDGE_IMAGE` | `cpd-remotive-bridge:latest` | Bridge image tag |

After editing config:

```bash
docker compose up -d bridge --force-recreate
docker logs -f cpd-bridge
```

---

## Drive CPD from Remotive (restbus)

If you cannot change signals from Studio UI, use restbus on the **running** broker:

```bash
# Register + start cyclic OpenDoorMsg (once per broker session / after reset)
remotive broker restbus add \
  --url http://127.0.0.1:50130 \
  --frame 'topology-BodyCAN:OpenDoorMsg' \
  --cycle-time 100 \
  --start

# State 1 — Child Detected + sound
remotive broker restbus update --url http://127.0.0.1:50130 \
  --signal 'topology-BodyCAN:OpenDoorMsg.Door_Cmd:1' \
  --signal 'topology-BodyCAN:OpenDoorMsg.Door_Target:1'

# State 2 — Escalation + sound
remotive broker restbus update --url http://127.0.0.1:50130 \
  --signal 'topology-BodyCAN:OpenDoorMsg.Door_Cmd:1' \
  --signal 'topology-BodyCAN:OpenDoorMsg.Door_Target:0'

# State 0 — clear
remotive broker restbus update --url http://127.0.0.1:50130 \
  --signal 'topology-BodyCAN:OpenDoorMsg.Door_Cmd:0' \
  --signal 'topology-BodyCAN:OpenDoorMsg.Door_Target:0'
```

Helper script (cycles all three states and prints bridge logs):

```bash
./scripts/test-remotive-cpd.sh
```

**Tip:** After `remotive broker restbus reset`, run `add --start` again before `update`, or frames may not cycle on the bus.

---

## Ports

| Port | Service |
|------|---------|
| **8443** | Cuttlefish WebRTC console (view AAOS UI) |
| **6520** | ADB |
| 1443 | Orchestrator / signaling |
| 9300 | VHAL proxy (optional) |
| 50130 | Remotive topology broker (host, external to this compose) |

---

## Manual control (without Remotive)

```bash
adb connect localhost:6520

# Prefer broadcast (reliable while app is already resumed on AAOS user 10)
adb shell am broadcast --user 10 -a com.emtek.cpd.SET_STATE \
  -n com.emtek.cpd/.MainActivity --ei state 1 --ez sound true

# Or activity intent
adb shell am start --user 10 -n com.emtek.cpd/.MainActivity \
  -a com.emtek.cpd.SET_STATE --ei state 2 --ez sound true
```

| `state` | Meaning |
|--------:|---------|
| `0` / `3` | None |
| `1` | Child Detected |
| `2` | Escalation |

JS API inside the WebView: `CPD.setState(1, { sound: true })`, `CPD.getState()`, `CPD.getStateCode()`.

---

## Docker images & CI

CI ([`.github/workflows/build-images.yml`](.github/workflows/build-images.yml)) builds **both** images on push to `main`/`master`, version tags `v*`, and pull requests (PR = build only, no push).

| Image | Dockerfile | GHCR name (example) |
|-------|------------|---------------------|
| Cuttlefish + CPD | [`cuttlefish/Dockerfile`](cuttlefish/Dockerfile) | `ghcr.io/minhtuan76800310/remotive_cuttlefish_cpd/cpd-cuttlefish` |
| Bridge | [`bridge/Dockerfile`](bridge/Dockerfile) | `ghcr.io/minhtuan76800310/remotive_cuttlefish_cpd/cpd-remotive-bridge` |

Tags published: `latest` (default branch), `sha-<short>`, semver on `v*` tags, branch/PR refs.

### Local image build

```bash
./scripts/build-images.sh
# or separately:
./scripts/build-apk.sh
docker build -t cpd-cuttlefish:latest -f cuttlefish/Dockerfile .
docker build -t cpd-remotive-bridge:latest -f bridge/Dockerfile bridge
```

### Pull CI images and run

```bash
export CUTTLEFISH_IMAGE=ghcr.io/minhtuan76800310/remotive_cuttlefish_cpd/cpd-cuttlefish:latest
export BRIDGE_IMAGE=ghcr.io/minhtuan76800310/remotive_cuttlefish_cpd/cpd-remotive-bridge:latest

# private GHCR package: docker login ghcr.io -u USER --password-stdin <<< "$CR_PAT"
docker compose pull
docker compose up -d
```

### First-time GHCR notes

- Packages are created under the GitHub user/org after the first successful workflow on `master`/`main`.
- If packages are private, grant pull access or use a PAT with `read:packages`.
- Workflow uses `GITHUB_TOKEN` with `packages: write` (no extra secret required for push from Actions).

---

## Repository layout

```
.
├── app/ChildPresentDetection/   # Android WebView app (com.emtek.cpd)
├── bridge/
│   ├── config.yaml              # Remotive + ADB endpoints (editable)
│   ├── main.py                  # Subscribe + map + adb SET_STATE
│   ├── Dockerfile
│   └── requirements.txt
├── cuttlefish/
│   ├── Dockerfile               # Base AAOS image + init + baked APK
│   ├── init.sh                  # Boot: launch_cvd, install APK, start CPD
│   └── apks/ChildPresentDetection.apk
├── scripts/
│   ├── build-apk.sh
│   ├── build-images.sh          # APK + both Docker images
│   ├── run-all.sh               # compose up + wait for :8443
│   ├── deploy-apk.sh            # rebuild + adb install on live guest
│   └── test-remotive-cpd.sh     # restbus cycle helper
├── docker-compose.yml           # cuttlefish + bridge
├── .github/workflows/build-images.yml
├── cpd_hmi_cluster.html         # HMI reference
└── README.md
```

---

## Troubleshooting

| Symptom | What to check |
|---------|----------------|
| UI never changes when Remotive signals change | `docker logs -f cpd-bridge` — expect `CPD state=…`. Rebuild/redeploy APK if missing: `./scripts/deploy-apk.sh` |
| Bridge connected but no signal batches | Restbus not started: `restbus add … --start`. Confirm namespace/signal names with `remotive broker signals list --url http://127.0.0.1:50130` |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Signature change: deploy script uninstalls + reinstalls automatically |
| Blank / old UI after update | Force-stop + relaunch: `adb shell am force-stop com.emtek.cpd && adb shell am start -n com.emtek.cpd/.MainActivity` |
| ADB / multi-user (AAOS) | App often runs as **user 10**. Bridge auto-detects; manual: `am … --user 10` |
| Port 8443 slow | First boot is long: `docker logs -f cpd-cuttlefish` |
| Broker only on 127.0.0.1 | Keep bridge on `network_mode: host` (default) |

Verify app received control:

```bash
docker exec cpd-cuttlefish /root/bin/adb -s localhost:6520 logcat -s ChildPresentDetection:I
# expect: control intent state=… / JS result="ok state=…"
```

---

## License / base images

- AAOS guest runtime: RemotiveLabs Cuttlefish image (respect their terms).
- Application and bridge code in this repository: project-local demo for integration testing.
