# Guide: HTML mock → Cuttlefish CPD app UI

How to take a **standalone HTML** design (browser mock / designer handoff) and make the **AAOS Cuttlefish** Child Present Detection app look and behave the same.

| Role | Path |
|------|------|
| **Live UI inside the guest** | `app/ChildPresentDetection/app/src/main/assets/index.html` |
| Reference cluster HMI | `cpd_hmi_cluster.html` (repo root) |
| Older multi-state demo | `cpd_hmi_demo.html` (simulator chrome — **do not** ship as-is) |
| Android WebView shell | `app/.../MainActivity.java` (loads assets; rarely needs UI edits) |

After any change to `assets/index.html`, you must **rebuild + reinstall the APK** (section 7). Editing HTML on the host does **not** hot-reload the guest.

---

## 1. How the app shows HTML

```
MainActivity (WebView)
    └── loads https://appassets.androidplatform.net/index.html
            └── served from APK assets/ via shouldInterceptRequest
```

- There is **no** React/Vue build step. The APK embeds a **single** `index.html` (inline CSS + JS is preferred).
- External control does **not** redraw from Java layouts. Java only calls:

  ```js
  window.CPD.setState(state, { sound: true|false })
  ```

- Remotive → bridge → ADB Intent still works as long as `window.CPD` stays compatible (section 4).

**Implication:** almost all visual work is “edit HTML/CSS/JS in `assets/index.html`”.

---

## 2. Recommended workflow

```text
1. Design / iterate in the browser on a root HTML file
   (e.g. cpd_hmi_cluster.html or a new mock).
2. Strip simulator-only chrome (buttons, keyboard shortcuts, WebSocket panels).
3. Copy (or merge) into assets/index.html.
4. Keep / restore the production window.CPD API + required DOM ids.
5. Open assets/index.html in a desktop browser and smoke-test CPD.setState(0|1|2).
6. ./scripts/deploy-apk.sh
7. Open https://localhost:8443 and verify on the guest.
8. Optional: re-test Remotive restbus → UI (see README / config_guide_4agent.md).
```

### Quick browser check (before APK)

```bash
# From repo root — any static server is fine
python3 -m http.server 8765 --directory app/ChildPresentDetection/app/src/main/assets
# Open http://127.0.0.1:8765/index.html
# DevTools console:
#   CPD.setState(1, {sound:true})
#   CPD.setState(2, {sound:true})
#   CPD.setState(0)
```

---

## 3. What must stay the same (contract)

If you break these, Remotive/bridge still “works” (Intents fire) but the **UI will not change** or JS will throw.

### 3.1 Global API: `window.CPD`

`MainActivity` evaluates roughly:

```js
CPD.setState(code, { sound: true|false })
```

Minimum surface the app and bridge expect:

| API | Behavior |
|-----|----------|
| `CPD.setState(next, opts?)` | Accept `0\|1\|2\|3` and names `'none'\|'detected'\|'escalation'`. `opts.sound` boolean. Return truthy on success. |
| `CPD.getState()` | `'none' \| 'detected' \| 'escalation'` |
| `CPD.getStateCode()` | `0 \| 1 \| 2` |
| `CPD.childDetected(opts?)` | → state 1 |
| `CPD.escalation(opts?)` | → state 2 |
| `CPD.none()` | → state 0 |
| `CPD.STATES` | `{ NONE:0, DETECTED:1, ESCALATION:2 }` (optional but useful) |

**State codes (do not renumber without updating bridge + docs):**

| Code | Name | Typical UI |
|-----:|------|------------|
| `0` or `3` | none | Idle cluster, no alert |
| `1` | detected | Child-present telltale / footer warning |
| `2` | escalation | Full-screen “Check Rear Seat” (or equivalent) |

Optional: `window.addEventListener('message', …)` for `{ type:'cpd', state, sound }` — nice for future embeds; not required by the current bridge.

### 3.2 DOM ids the stock script uses

Keep these **ids** (or update the JS in the same file if you rename them):

| id | Role |
|----|------|
| `escalation` | Full-screen alert root; class `show` when state = escalation |
| `tt-cpd` | CPD telltale; classes `on` + `blink` when active |
| `cpd-dot` | Footer status dot; classes `detected` / `escalation` |
| `cpd-label` | Footer text |
| `speed-num` | Optional ambient speed (script animates) |
| `clock` | Optional clock |
| `tt-seatbelt` | Optional boot flash |

CSS hooks used by JS:

- `.escalation.show { display: … }`
- `.telltale.on` / `.telltale.blink`
- `.cpd-dot.detected` / `.cpd-dot.escalation`

You may restyle freely; keep the **class names JS toggles** or change JS in lockstep.

### 3.3 What to remove from designer HTML

From `cpd_hmi_demo.html`-style mocks, **do not** ship into the guest:

- On-screen state buttons / “simulator” panels  
- Keyboard shortcuts that cycle states for demo  
- WebSocket / fake topology chrome  
- Autoplay slideshows that fight external control  
- Dependencies on external CDNs if the guest is offline (prefer inline SVG/CSS/JS)

Production HMI = **display + `window.CPD` only**. Topology drives state from outside.

---

## 4. Merge strategies

### Strategy A — Full replace (simplest when mock ≈ final)

When the new HTML is already a fullscreen cluster (like `cpd_hmi_cluster.html`):

```bash
# 1) Backup
cp app/ChildPresentDetection/app/src/main/assets/index.html \
   app/ChildPresentDetection/app/src/main/assets/index.html.bak

# 2) Copy mock → assets
cp cpd_hmi_cluster.html \
   app/ChildPresentDetection/app/src/main/assets/index.html

# 3) Re-apply production script contract (section 5)
#    Edit assets/index.html: ensure window.CPD + ids + sound option

# 4) Browser smoke-test, then deploy
./scripts/deploy-apk.sh
```

### Strategy B — Visual merge (keep production script)

1. Copy only `<style>` and markup from the mock into `assets/index.html`.  
2. Leave the existing `<script>… window.CPD …</script>` block at the bottom.  
3. Align ids/classes so the existing `setState()` still finds nodes.  
4. Deploy.

### Strategy C — New multi-file design (CSS/JS/images)

WebView can load sibling assets if you add them under `assets/`:

```text
assets/
  index.html
  css/theme.css
  js/cpd.js
  img/icon.svg
```

In HTML:

```html
<link rel="stylesheet" href="css/theme.css">
<script src="js/cpd.js"></script>
```

`MainActivity` serves any path under `assets/` for host `appassets.androidplatform.net`.  
Still call `window.CPD = { … }` from `cpd.js` before or on `DOMContentLoaded`.

Prefer **one file** unless the design is large — simpler APK packaging and fewer path bugs.

---

## 5. Production script checklist (paste / verify)

After bringing in new markup, confirm the bottom script still:

1. Defines `normalize()` mapping `0/1/2/3` and string aliases.  
2. Implements `setState(next, opts)` with `opts.sound`.  
3. Toggles escalation overlay + telltale + footer.  
4. Exposes `window.CPD`.  
5. Initializes with `setState(0)` (idle).  
6. Logs usefully: `console.log('[CPD] state →', …)` (helps `adb logcat -s ChildPresentDetection`).

Minimal skeleton (adapt selectors to your markup):

```html
<script>
(function () {
  const STATES = {
    0: 'none', 1: 'detected', 2: 'escalation', 3: 'none',
    none: 'none', detected: 'detected', escalation: 'escalation',
    alert: 'escalation', clear: 'none'
  };

  // REQUIRED nodes — change query only if you rename ids
  const escalation = document.getElementById('escalation');
  const ttCpd = document.getElementById('tt-cpd');
  const cpdDot = document.getElementById('cpd-dot');
  const cpdLabel = document.getElementById('cpd-label');

  let state = 'none';

  function normalize(next) {
    if (typeof next === 'number' && !isNaN(next)) next = String(Math.trunc(next));
    if (typeof next === 'string') next = next.trim().toLowerCase();
    return STATES[next] || null;
  }

  function setState(next, opts) {
    const s = normalize(next);
    if (!s) return false;
    state = s;
    const wantSound = !!(opts === true || (opts && opts.sound));

    const active = state !== 'none';
    if (ttCpd) {
      ttCpd.classList.toggle('on', active);
      ttCpd.classList.toggle('blink', active);
    }
    if (escalation) escalation.classList.toggle('show', state === 'escalation');
    if (cpdDot) cpdDot.className = 'cpd-dot' + (active ? ' ' + state : '');
    if (cpdLabel) {
      cpdLabel.textContent =
        state === 'detected' ? 'CPD: CHILD DETECTED' :
        state === 'escalation' ? 'CPD: ⚠ ALERT — CHECK REAR SEAT' :
        'CPD: NO OCCUPANT';
    }

    // optional: beep() using wantSound — see current index.html
    console.log('[CPD] state →', state, 'sound=', wantSound);
    return true;
  }

  window.CPD = {
    setState,
    getState: () => state,
    getStateCode: () => state === 'detected' ? 1 : state === 'escalation' ? 2 : 0,
    childDetected: (o) => setState(1, o),
    escalation: (o) => setState(2, o),
    none: () => setState(0),
    STATES: Object.freeze({ NONE: 0, DETECTED: 1, ESCALATION: 2 })
  };

  setState(0);
})();
</script>
```

Sound: copy the `AudioContext` beep helpers from the current `assets/index.html` if the mock had none. Bridge often sets `sound: true` for states 1 and 2.

---

## 6. AAOS / WebView UI constraints

| Topic | Guidance |
|-------|----------|
| Viewport | Fullscreen landscape cluster; `html,body { height:100%; overflow:hidden }` |
| Safe area | Avoid critical text at extreme edges (system bars can flash) |
| Fonts | System fonts (`Segoe UI`, `Roboto`) — no required webfont downloads |
| Color | High contrast; escalation must be obvious at a glance |
| Motion | Prefer CSS animation; avoid heavy canvas unless needed |
| Touch | Not required for CPD (signal-driven); don’t rely on hover-only states |
| Autoplay audio | May be blocked until a user gesture; sound is best-effort |
| `file://` | Don’t use; app uses virtual HTTPS asset host |
| Mixed content | Inline or same-origin assets only |
| Debug | `WebView.setWebContentsDebuggingEnabled(true)` already on — use chrome://inspect if needed |

Display size is set in `cuttlefish/init.sh` (`CUTTLEFISH_DISPLAY_MAIN`, default ~1400×800). Design around a wide automotive cluster, not a phone portrait mock.

---

## 7. Deploy to Cuttlefish

Guest must be running (`cpd-cuttlefish` up, ADB `:6520`).

```bash
# From repo root — rebuild APK + adb install + launch MainActivity
./scripts/deploy-apk.sh
```

Manual equivalent:

```bash
./scripts/build-apk.sh
# APK → cuttlefish/apks/ChildPresentDetection.apk (also bind-mounted in container)

docker exec cpd-cuttlefish /root/bin/adb -s localhost:6520 install -r \
  /root/apks/ChildPresentDetection.apk
# on signature mismatch: uninstall com.emtek.cpd then install

docker exec cpd-cuttlefish /root/bin/adb -s localhost:6520 shell \
  am force-stop com.emtek.cpd
docker exec cpd-cuttlefish /root/bin/adb -s localhost:6520 shell \
  am start -n com.emtek.cpd/.MainActivity
```

Open **https://localhost:8443** and reconnect WebRTC if the stream was stale.

### Verify states on device

```bash
ADB='docker exec cpd-cuttlefish /root/bin/adb -s localhost:6520'
$ADB logcat -c
$ADB shell am broadcast --user 10 -a com.emtek.cpd.SET_STATE \
  -n com.emtek.cpd/.MainActivity --ei state 2 --ez sound true
$ADB logcat -d -s ChildPresentDetection:I | tail -20
# expect: JS result="ok state=escalation …"
```

---

## 8. Keep repo reference HTML in sync (optional)

When the guest UI is the source of truth:

```bash
cp app/ChildPresentDetection/app/src/main/assets/index.html cpd_hmi_cluster.html
# Commit both so designers and the app stay aligned
```

When the designer owns `cpd_hmi_cluster.html`, treat **assets/index.html** as the production fork (API + no simulator), and merge forward carefully.

---

## 9. Do you need to change Java?

| Change | Edit Java? |
|--------|------------|
| Colors, layout, fonts, SVG, animations | **No** — HTML/CSS only |
| New CPD state codes / rename Intent extras | **Yes** — `MainActivity` + bridge mapping + this guide |
| Load a different start file than `index.html` | **Yes** — `START_URL` / assets path |
| Extra native permissions / sensors | **Yes** — Manifest + Java |

For pure visual redesigns, **do not** touch `MainActivity.java`.

---

## 10. Agent / automation checklist

```text
[ ] Identify source HTML (designer file or cpd_hmi_*.html)
[ ] Backup assets/index.html
[ ] Merge markup/CSS; strip simulator chrome
[ ] Preserve window.CPD + state 0/1/2 + sound option
[ ] Preserve or rewire DOM ids used by setState
[ ] Browser smoke-test CPD.setState(0|1|2)
[ ] ./scripts/deploy-apk.sh
[ ] Guest UI check on :8443
[ ] logcat JS result ok
[ ] Optional: restbus 1/1, 1/0, 0/0 still drives UI
[ ] Optional: sync cpd_hmi_cluster.html + commit
```

---

## 11. Common mistakes

| Mistake | Result | Fix |
|---------|--------|-----|
| Only edited root `cpd_hmi_*.html` | Guest UI unchanged | Copy into `assets/index.html` + deploy |
| Deployed HTML but forgot APK rebuild | Old UI | `./scripts/deploy-apk.sh` |
| Removed `window.CPD` | Intent no-ops / JS errors | Restore API skeleton |
| Renamed `#escalation` without JS update | No overlay | Fix id or JS |
| Changed state meanings (e.g. 1 = escalation) | Remotive mapping wrong | Keep codes; only change visuals |
| External CDN CSS | Blank/broken offline | Inline or ship under `assets/` |
| Left demo auto-cycle timer | UI fights bridge | Remove timers that call `setState` |

---

## 12. Related docs

| Doc | Use when |
|-----|----------|
| [`README.md`](README.md) | Run stack, Remotive mapping, ports |
| [`config_guide_4agent.md`](config_guide_4agent.md) | Agent ops: broker, bridge, debug L1–L4 |
| This file | **Change how CPD looks** from HTML |

---

*End of UI HTML → Cuttlefish guide.*
