#!/usr/bin/env python3
"""RemotiveLabs Topology → Child Present Detection bridge.

Subscribes to OpenDoorMsg.Door_Cmd / OpenDoorMsg.Door_Target on a Remotive
broker and drives the CPD app in Cuttlefish via ADB Intent SET_STATE.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml
from remotivelabs.broker import BrokerClient
from remotivelabs.broker.auth import ApiKeyAuth, NoAuth

LOG = logging.getLogger("cpd-bridge")


@dataclass(frozen=True)
class Rule:
    door_cmd: int
    door_target: int
    cpd_state: int
    sound: bool


@dataclass
class Config:
    broker_url: str
    api_key: str
    namespace: str
    door_cmd_signal: str
    door_target_signal: str
    on_change: bool
    adb_serial: str
    adb_path: str
    package: str
    activity: str
    intent_action: str
    reconnect_interval_s: float
    min_intent_interval_s: float
    rules: list[Rule]


def _as_int(value: Any, default: int = 0) -> int:
    if value is None:
        return default
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def load_config(path: Path) -> Config:
    with path.open("r", encoding="utf-8") as fh:
        raw = yaml.safe_load(fh) or {}

    rem = raw.get("remotive") or {}
    cut = raw.get("cuttlefish") or {}
    mapping = raw.get("mapping") or {}
    rules_raw = mapping.get("rules") or []

    rules: list[Rule] = []
    for r in rules_raw:
        rules.append(
            Rule(
                door_cmd=_as_int(r.get("door_cmd")),
                door_target=_as_int(r.get("door_target")),
                cpd_state=_as_int(r.get("cpd_state")),
                sound=bool(r.get("sound", False)),
            )
        )
    if not rules:
        rules = [
            Rule(1, 1, 1, True),
            Rule(0, 0, 0, False),
            Rule(1, 0, 2, True),
        ]

    # Env overrides (useful in compose without editing the file)
    broker_url = os.environ.get("REMOTIVE_BROKER_URL") or rem.get(
        "broker_url", "http://127.0.0.1:50130"
    )
    adb_serial = os.environ.get("CUTTLEFISH_ADB") or cut.get(
        "adb_serial", "127.0.0.1:6520"
    )
    namespace = os.environ.get("REMOTIVE_NAMESPACE") or rem.get(
        "namespace", "topology-BodyCAN"
    )

    return Config(
        broker_url=str(broker_url),
        api_key=str(
            os.environ.get("REMOTIVE_BROKER_API_KEY") or rem.get("api_key") or ""
        ),
        namespace=str(namespace),
        door_cmd_signal=str(rem.get("door_cmd_signal", "OpenDoorMsg.Door_Cmd")),
        door_target_signal=str(
            rem.get("door_target_signal", "OpenDoorMsg.Door_Target")
        ),
        on_change=bool(rem.get("on_change", True)),
        adb_serial=str(adb_serial),
        adb_path=str(cut.get("adb_path") or shutil.which("adb") or "adb"),
        package=str(cut.get("package", "com.emtek.cpd")),
        activity=str(cut.get("activity", "com.emtek.cpd/.MainActivity")),
        intent_action=str(cut.get("intent_action", "com.emtek.cpd.SET_STATE")),
        reconnect_interval_s=float(cut.get("reconnect_interval_s", 5)),
        min_intent_interval_s=float(cut.get("min_intent_interval_s", 0.3)),
        rules=rules,
    )


def map_state(door_cmd: int, door_target: int, rules: list[Rule]) -> tuple[int, bool] | None:
    for rule in rules:
        if rule.door_cmd == door_cmd and rule.door_target == door_target:
            return rule.cpd_state, rule.sound
    return None


class AdbCpdClient:
    """Thin wrapper: ensure device online, fire SET_STATE via broadcast (+ start fallback)."""

    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self._last_key: tuple[int, bool] | None = None
        self._last_sent_at = 0.0
        self._connected = False
        # AAOS often runs the launcher app as a secondary user (e.g. 10).
        self._user: str | None = None

    def _run(self, args: list[str], timeout: float = 15.0) -> subprocess.CompletedProcess[str]:
        cmd = [self.cfg.adb_path, *args]
        LOG.debug("adb: %s", " ".join(cmd))
        return subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def _shell(self, *shell_args: str, timeout: float = 15.0) -> subprocess.CompletedProcess[str]:
        return self._run(["-s", self.cfg.adb_serial, "shell", *shell_args], timeout=timeout)

    def _detect_user(self) -> str:
        """Find the Android user that has com.emtek.cpd running / installed."""
        # Prefer the user that currently owns the resumed CPD activity.
        r = self._shell("dumpsys", "activity", "activities", timeout=20)
        text = r.stdout or ""
        import re

        m = re.search(r"topResumedActivity=.*com\.emtek\.cpd", text)
        if m:
            # look backwards for "u10" style token near the match
            window = text[max(0, m.start() - 200) : m.end() + 50]
            um = re.search(r"\bu(\d+)\b", window)
            if um:
                return um.group(1)
        # ActivityRecord{... u10 com.emtek.cpd
        m = re.search(r"\bu(\d+)\s+com\.emtek\.cpd", text)
        if m:
            return m.group(1)
        # Fallback: current user
        r = self._shell("am", "get-current-user", timeout=10)
        cur = (r.stdout or "").strip()
        if cur.isdigit():
            return cur
        return "0"

    def ensure_device(self) -> bool:
        serial = self.cfg.adb_serial
        # connect for TCP serials
        if ":" in serial:
            r = self._run(["connect", serial], timeout=10)
            out = (r.stdout or "") + (r.stderr or "")
            if r.returncode != 0 and "connected" not in out.lower() and "already" not in out.lower():
                LOG.warning("adb connect %s failed: %s", serial, out.strip())
                self._connected = False
                return False

        r = self._run(["-s", serial, "get-state"], timeout=10)
        state = (r.stdout or "").strip()
        if state != "device":
            LOG.warning("adb device state=%r (want device)", state or (r.stderr or "").strip())
            self._connected = False
            return False

        if not self._connected or self._user is None:
            self._user = self._detect_user()
            LOG.info("ADB ready: %s  android_user=%s", serial, self._user)
            # Bring CPD to foreground once so WebView is alive
            self._shell(
                "am",
                "start",
                "--user",
                self._user,
                "-n",
                self.cfg.activity,
                timeout=15,
            )
            self._connected = True
        return True

    def set_state(self, state: int, sound: bool, force: bool = False) -> bool:
        now = time.monotonic()
        key = (state, sound)
        if (
            not force
            and key == self._last_key
            and (now - self._last_sent_at) < self.cfg.min_intent_interval_s
        ):
            return True

        if not self.ensure_device():
            return False

        user = self._user or "0"
        extras = [
            "--ei",
            "state",
            str(int(state)),
            "--ez",
            "sound",
            "true" if sound else "false",
        ]

        # 1) Explicit broadcast to the running activity's process (most reliable
        #    when the activity is already resumed / singleTask).
        r_bc = self._shell(
            "am",
            "broadcast",
            "--user",
            user,
            "-a",
            self.cfg.intent_action,
            "-n",
            f"{self.cfg.package}/.MainActivity",
            *extras,
            timeout=15,
        )
        out_bc = ((r_bc.stdout or "") + (r_bc.stderr or "")).strip()

        # 2) Also deliver via start → onNewIntent (covers cold start).
        r_st = self._shell(
            "am",
            "start",
            "--user",
            user,
            "-n",
            self.cfg.activity,
            "-a",
            self.cfg.intent_action,
            *extras,
            timeout=15,
        )
        out_st = ((r_st.stdout or "") + (r_st.stderr or "")).strip()

        ok = r_bc.returncode == 0 or r_st.returncode == 0
        if not ok:
            LOG.error(
                "SET_STATE failed broadcast=%s start=%s",
                out_bc,
                out_st,
            )
            self._connected = False
            self._user = None
            return False

        LOG.info(
            "CPD state=%s sound=%s user=%s  bc=[%s] start=[%s]",
            state,
            sound,
            user,
            out_bc.splitlines()[-1] if out_bc else "ok",
            out_st.splitlines()[-1] if out_st else "ok",
        )
        self._last_key = key
        self._last_sent_at = now
        return True


async def wait_for_adb(adb: AdbCpdClient, interval: float) -> None:
    while True:
        if await asyncio.to_thread(adb.ensure_device):
            return
        LOG.info("Waiting for Cuttlefish ADB (%ss)…", interval)
        await asyncio.sleep(interval)


async def run_bridge(cfg: Config) -> None:
    adb = AdbCpdClient(cfg)
    await wait_for_adb(adb, cfg.reconnect_interval_s)

    auth = ApiKeyAuth(cfg.api_key) if cfg.api_key else NoAuth()
    LOG.info(
        "Connecting to Remotive broker %s  ns=%s  signals=[%s, %s]",
        cfg.broker_url,
        cfg.namespace,
        cfg.door_cmd_signal,
        cfg.door_target_signal,
    )

    door_cmd = 0
    door_target = 0
    last_applied: tuple[int, bool] | None = None

    while True:
        try:
            async with BrokerClient(url=cfg.broker_url, auth=auth) as client:
                LOG.info("Broker connected (client_id=%s)", getattr(client, "client_id", "?"))
                # subscribe() is async and returns an AsyncIterator
                stream = await client.subscribe(
                    (cfg.namespace, [cfg.door_cmd_signal, cfg.door_target_signal]),
                    on_change=cfg.on_change,
                    initial_empty=True,
                )
                async for batch in stream:
                    touched = False
                    for sig in batch:
                        name = str(getattr(sig, "name", "") or "")
                        val = _as_int(getattr(sig, "value", 0))
                        if name == cfg.door_cmd_signal or name.endswith(".Door_Cmd") or name == "Door_Cmd":
                            if val != door_cmd:
                                door_cmd = val
                            touched = True
                        elif (
                            name == cfg.door_target_signal
                            or name.endswith(".Door_Target")
                            or name == "Door_Target"
                        ):
                            if val != door_target:
                                door_target = val
                            touched = True

                    if not touched:
                        continue

                    mapped = map_state(door_cmd, door_target, cfg.rules)
                    LOG.debug(
                        "signals Door_Cmd=%s Door_Target=%s → %s",
                        door_cmd,
                        door_target,
                        mapped,
                    )
                    if mapped is None or mapped == last_applied:
                        continue
                    state, sound = mapped
                    ok = await asyncio.to_thread(adb.set_state, state, sound)
                    if ok:
                        last_applied = mapped
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            LOG.warning("Broker session error: %s — reconnecting in 3s", exc)
            await asyncio.sleep(3)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Remotive → CPD Cuttlefish bridge")
    p.add_argument(
        "-c",
        "--config",
        default=os.environ.get("BRIDGE_CONFIG", "/config/config.yaml"),
        help="Path to config.yaml (default: $BRIDGE_CONFIG or /config/config.yaml)",
    )
    p.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Debug logging",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )

    cfg_path = Path(args.config)
    if not cfg_path.is_file():
        # fall back to sidecar next to this script
        alt = Path(__file__).resolve().parent / "config.yaml"
        if alt.is_file():
            cfg_path = alt
        else:
            LOG.error("Config not found: %s", args.config)
            return 2

    cfg = load_config(cfg_path)
    LOG.info("Loaded config from %s", cfg_path)
    LOG.info(
        "Mapping rules: %s",
        ", ".join(
            f"(cmd={r.door_cmd},tgt={r.door_target})→state{r.cpd_state}"
            + ("+snd" if r.sound else "")
            for r in cfg.rules
        ),
    )

    try:
        asyncio.run(run_bridge(cfg))
    except KeyboardInterrupt:
        LOG.info("Stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
