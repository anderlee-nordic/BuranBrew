"""Configuration, Matter I/O, and telemetry utilities."""

from __future__ import annotations

import logging
import os
import re
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

import yaml

try:
    import redis as _redis
except ImportError:  # telemetry is optional for the control loop
    _redis = None

log = logging.getLogger("buranbrew")
MEASURED_RE = re.compile(r"MeasuredValue:\s*(-?\d+)")
SENSOR_STREAM = "telemetry:sensor"
CONTROL_STREAM = "telemetry:control"
STATE_HASH = "telemetry:state"
STREAM_MAXLEN = 100_000
REQUIRED_HOST_ENV_KEYS = ("REDIS_PORT",)


@dataclass(frozen=True)
class ControlTuning:
    """Parameters that tune PI behaviour and time-proportional output."""

    kp: float
    ki_per_hour: float
    kff: float
    integral_limit: float
    integral_dt_max_s: float
    ambient_filter_alpha: float
    internal_filter_alpha: float
    window_s: float
    effort_deadband: float
    actuator_tick_s: float
    heat_min_on_s: float
    cool_min_on_s: float
    reverse_idle_s: float
    command_stale_timeout_s: float

    def validate(self, period_s: float) -> None:
        if self.integral_limit < 0.0:
            raise ValueError("control.integral_limit must be >= 0")
        if self.integral_dt_max_s <= 0.0:
            raise ValueError("control.integral_dt_max_s must be > 0")

        for name, alpha in (
            ("ambient_filter_alpha", self.ambient_filter_alpha),
            ("internal_filter_alpha", self.internal_filter_alpha),
        ):
            if not 0.0 < alpha <= 1.0:
                raise ValueError(f"control.{name} must be in (0, 1]")

        if self.window_s <= 0.0:
            raise ValueError("control.window_s must be > 0")
        if self.actuator_tick_s <= 0.0:
            raise ValueError("control.actuator_tick_s must be > 0")
        if not 0.0 <= self.effort_deadband < 1.0:
            raise ValueError("control.effort_deadband must be in [0, 1)")

        for name, value in (
            ("heat_min_on_s", self.heat_min_on_s),
            ("cool_min_on_s", self.cool_min_on_s),
            ("reverse_idle_s", self.reverse_idle_s),
            ("command_stale_timeout_s", self.command_stale_timeout_s),
        ):
            if value < 0.0:
                raise ValueError(f"control.{name} must be >= 0")

        if self.heat_min_on_s > self.window_s:
            raise ValueError("control.heat_min_on_s must be <= control.window_s")
        if self.cool_min_on_s > self.window_s:
            raise ValueError("control.cool_min_on_s must be <= control.window_s")
        if self.command_stale_timeout_s < period_s:
            raise ValueError("control.command_stale_timeout_s must be >= period_s")


@dataclass(frozen=True)
class Config:
    chip_tool: str
    storage_dir: str
    node_sensor: int
    node_plug_heat: int
    node_plug_cool: int
    ep_ambient: int
    ep_internal: int
    ep_gravity: int
    setpoint_c: float
    ambient_offset_c: float
    internal_offset_c: float
    sg_offset: float
    period_s: float
    chip_timeout_s: int
    redis_url: str
    control: ControlTuning

    @staticmethod
    def load(path: Path) -> "Config":
        _load_host_env_defaults()
        raw = yaml.safe_load(path.read_text())
        nodes = raw["nodes"]
        endpoints = raw["endpoints"]
        control = raw["control"]

        tuning = ControlTuning(
            kp=float(control["kp"]),
            ki_per_hour=float(control["ki_per_hour"]),
            kff=float(control["kff"]),
            integral_limit=float(control["integral_limit"]),
            integral_dt_max_s=float(control["integral_dt_max_s"]),
            ambient_filter_alpha=float(control["ambient_filter_alpha"]),
            internal_filter_alpha=float(control["internal_filter_alpha"]),
            window_s=float(control["window_s"]),
            effort_deadband=float(control["effort_deadband"]),
            actuator_tick_s=float(control["actuator_tick_s"]),
            heat_min_on_s=float(control["heat_min_on_s"]),
            cool_min_on_s=float(control["cool_min_on_s"]),
            reverse_idle_s=float(control["reverse_idle_s"]),
            command_stale_timeout_s=float(control["command_stale_timeout_s"]),
        )

        period_s = float(raw["period_s"])
        if period_s <= 0.0:
            raise ValueError("period_s must be > 0")
        tuning.validate(period_s)

        return Config(
            chip_tool=os.path.expanduser(str(raw["chip_tool"])),
            storage_dir=os.path.expanduser(str(raw["storage_dir"])),
            node_sensor=int(nodes["sensor"]),
            node_plug_heat=int(nodes["plug_heat"]),
            node_plug_cool=int(nodes["plug_cool"]),
            ep_ambient=_positive_endpoint(endpoints, "ambient"),
            ep_internal=_positive_endpoint(endpoints, "internal"),
            ep_gravity=_positive_endpoint(endpoints, "gravity"),
            setpoint_c=float(raw["setpoint_c"]),
            ambient_offset_c=float(raw.get("ambient_offset_c", 0.0)),
            internal_offset_c=float(raw.get("internal_offset_c", 0.0)),
            sg_offset=float(raw.get("sg_offset", 0.0)),
            period_s=period_s,
            chip_timeout_s=int(raw.get("chip_timeout_s", 30)),
            redis_url=os.path.expandvars(
                str((raw.get("redis") or {}).get("url", ""))
            ),
            control=tuning,
        )


def _load_host_env_defaults() -> None:
    """Load runtime-only values from host.env before expanding config values."""
    path = Path(os.environ.get("BURANBREW_HOST_ENV", "host.env")).expanduser().resolve()
    if not path.is_file():
        raise RuntimeError(f"host.env not found: {path}")

    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key not in REQUIRED_HOST_ENV_KEYS:
            continue
        value = value.split("#", 1)[0].strip().strip("'\"")
        if value:
            values[key] = value

    missing = [key for key in REQUIRED_HOST_ENV_KEYS if key not in values]
    if missing:
        raise RuntimeError(
            f"{path}: missing required setting(s): {', '.join(missing)}"
        )
    os.environ.update(values)


def _positive_endpoint(endpoints: dict, name: str) -> int:
    endpoint = int(endpoints[name])
    if endpoint <= 0:
        raise ValueError(f"endpoints.{name} must be a positive integer")
    return endpoint


class ChipTool:
    """Small adapter around Matter chip-tool."""

    def __init__(self, cfg: Config):
        self._cfg = cfg

    def _run(self, *args: str) -> str:
        proc = subprocess.run(
            [
                self._cfg.chip_tool,
                *args,
                "--storage-directory",
                self._cfg.storage_dir,
            ],
            capture_output=True,
            text=True,
            timeout=self._cfg.chip_timeout_s,
        )
        if proc.returncode:
            tail = proc.stderr.strip().splitlines()[-1:] or ["?"]
            raise RuntimeError(
                f"chip-tool {' '.join(args)} rc={proc.returncode}: {tail[-1]}"
            )
        return proc.stdout

    def _read(self, cluster: str, node: int, endpoint: int) -> int:
        output = self._run(
            cluster, "read", "measured-value", str(node), str(endpoint)
        )
        matches = MEASURED_RE.findall(output)
        if not matches:
            raise RuntimeError(f"no MeasuredValue in output for {node}/{endpoint}")
        return int(matches[-1])

    def read_temp_centi(self, node: int, endpoint: int) -> int:
        return self._read("temperaturemeasurement", node, endpoint)

    def read_gravity_milli(self, node: int, endpoint: int) -> int:
        return self._read("relativehumiditymeasurement", node, endpoint)

    def set_plug(self, node: int, on: bool) -> None:
        self._run("onoff", "on" if on else "off", str(node), "1")


class Emitter:
    """Best-effort Redis telemetry; failures never enter the control loop."""

    def __init__(self, cfg: Config):
        self._node, self._r = cfg.node_sensor, None
        if not cfg.redis_url:
            log.info("telemetry: disabled (no redis.url in config)")
        elif _redis is None:
            log.warning("telemetry: disabled (python redis package missing)")
        else:
            self._r = _redis.Redis.from_url(
                cfg.redis_url,
                socket_timeout=0.25,
                socket_connect_timeout=0.25,
            )
            log.info("telemetry: emitting to %s", cfg.redis_url)

    @staticmethod
    def _now_ms() -> int:
        return time.time_ns() // 1_000_000

    def _xadd(self, stream: str, fields: dict) -> None:
        if self._r is None:
            return
        try:
            self._r.xadd(stream, fields, maxlen=STREAM_MAXLEN, approximate=True)
        except Exception as exc:  # telemetry must remain non-fatal
            log.debug("emit %s dropped: %s", stream, exc)

    def sensor(self, metric: str, value: float) -> None:
        self._xadd(
            SENSOR_STREAM,
            {
                "ts_ms": self._now_ms(),
                "node": self._node,
                "metric": metric,
                "value": f"{value:.4f}",
            },
        )

    def control(
        self,
        *,
        action: str,
        diff_centi: int,
        effort: float,
        duty_cycle: float,
        active_s: float,
        window_s: float,
        reason: str,
    ) -> None:
        self._xadd(
            CONTROL_STREAM,
            {
                "ts_ms": self._now_ms(),
                "action": action,
                "diff_centi": diff_centi,
                "source": "model",
                "effort": f"{effort:.4f}",
                "duty_cycle": f"{duty_cycle:.4f}",
                "active_s": f"{active_s:.1f}",
                "window_s": f"{window_s:.1f}",
                "reason": reason,
            },
        )

    def state(
        self,
        *,
        ambient: float,
        internal: float,
        sg: float | None,
        action: str,
        effort: float,
    ) -> None:
        if self._r is None:
            return
        try:
            self._r.hset(
                STATE_HASH,
                mapping={
                    "ambient": f"{ambient:.2f}",
                    "internal": f"{internal:.2f}",
                    "sg": f"{sg:.3f}" if sg is not None else "n/a",
                    "action": action,
                    "effort": f"{effort:.4f}",
                    "updated_ms": self._now_ms(),
                },
            )
        except Exception as exc:
            log.debug("emit state dropped: %s", exc)

