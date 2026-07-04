#!/usr/bin/env python3
"""BuranBrew control model"""

from __future__ import annotations

import logging
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import yaml

try:
    import redis as _redis
except ImportError:  # telemetry optional
    _redis = None

log = logging.getLogger("buranbrew")
MEASURED_RE = re.compile(r"MeasuredValue:\s*(-?\d+)")
SENSOR_STREAM = "telemetry:sensor"
CONTROL_STREAM = "telemetry:control"
STATE_HASH = "telemetry:state"
STREAM_MAXLEN = 100_000


REQUIRED_HOST_ENV_KEYS = ("REDIS_PORT",)


def _load_host_env_defaults(cfg_path: Path) -> None:
    '''
    nix run packages config.yaml in /nix/store, so resolve host.env from the
    runtime working directory instead of relative to the packaged config.
    BURANBREW_HOST_ENV remains an explicit override for service launches.
    '''
    del cfg_path  # kept in the signature for Config.load compatibility
    path = Path(os.environ.get("BURANBREW_HOST_ENV", "host.env")).expanduser()
    path = path.resolve()
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


def _required_positive_endpoint(endpoints: dict, name: str) -> int:
    """Return a mandatory positive endpoint ID from the configuration."""
    endpoint = int(endpoints[name])
    if endpoint <= 0:
        raise ValueError(f"endpoints.{name} must be a positive integer")
    return endpoint


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
    period_s: int
    chip_timeout_s: int
    redis_url: str

    @staticmethod
    def load(path: Path) -> "Config":
        _load_host_env_defaults(path)
        raw = yaml.safe_load(path.read_text())
        nodes, endpoints = raw["nodes"], raw["endpoints"]
        return Config(
            os.path.expanduser(raw["chip_tool"]),
            os.path.expanduser(raw["storage_dir"]),
            int(nodes["sensor"]),
            int(nodes["plug_heat"]),
            int(nodes["plug_cool"]),
            int(endpoints["ambient"]),
            int(endpoints["internal"]),
            _required_positive_endpoint(endpoints, "gravity"),
            float(raw["setpoint_c"]),
            float(raw.get("ambient_offset_c", 0.0)),
            float(raw.get("internal_offset_c", 0.0)),
            float(raw.get("sg_offset", 0.0)),
            int(raw["period_s"]),
            int(raw.get("chip_timeout_s", 30)),
            os.path.expandvars(str((raw.get("redis") or {}).get("url", ""))),
        )


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
                cfg.redis_url, socket_timeout=0.25, socket_connect_timeout=0.25
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
        self._xadd(SENSOR_STREAM, {
            "ts_ms": self._now_ms(), "node": self._node,
            "metric": metric, "value": f"{value:.4f}",
        })

    def control(self, action: str, diff_centi: int) -> None:
        self._xadd(CONTROL_STREAM, {
            "ts_ms": self._now_ms(), "action": action,
            "diff_centi": diff_centi, "source": "model",
        })

    def state(self, ambient: float, internal: float,
              sg: float | None, action: str) -> None:
        if self._r is None:
            return
        try:
            self._r.hset(STATE_HASH, mapping={
                "ambient": f"{ambient:.2f}",
                "internal": f"{internal:.2f}",
                "sg": f"{sg:.3f}" if sg is not None else "n/a",
                "action": action,
                "updated_ms": self._now_ms(),
            })
        except Exception as exc:
            log.debug("emit state dropped: %s", exc)


class ChipTool:
    def __init__(self, cfg: Config):
        self._cfg = cfg

    def _run(self, *args: str) -> str:
        proc = subprocess.run(
            [self._cfg.chip_tool, *args,
             "--storage-directory", self._cfg.storage_dir],
            capture_output=True,
            text=True,
            timeout=self._cfg.chip_timeout_s,
        )
        if proc.returncode:
            tail = proc.stderr.strip().splitlines()[-1:] or "?"
            raise RuntimeError(
                f"chip-tool {' '.join(args)} rc={proc.returncode}: {tail}"
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


@dataclass(frozen=True)
class ControlDecision:
    action: str
    effort: float
    error_c: float
    p_term: float
    i_term: float
    feedforward_term: float


class ControlModel:
    """Compute the control decision.

    The model combines PI feedback on calibrated internal temperature with
    feedforward compensation from room temperature. Its normalized effort is
    mapped to the existing ``HEAT``, ``COOL``, and ``IDLE`` actions using
    hysteresis, integral limiting, and basic anti-windup.
    """

    # All parameters are based on guessing hehe...
    KP = 0.60
    KI_PER_HOUR = 0.08
    KFF = 0.04
    INTEGRAL_LIMIT = 0.50
    START_THRESHOLD = 0.15
    STOP_THRESHOLD = 0.05

    def __init__(self, period_s: int):
        """Initialize controller state for the configured update period."""
        self._period_s = float(period_s)
        self._integral = 0.0
        self._last_update: float | None = None
        self._last_action = "IDLE"

    @staticmethod
    def _clamp(value: float, low: float, high: float) -> float:
        return max(low, min(high, value))

    def update(self, *, setpoint_c: float, internal_c: float,
               ambient_c: float, now: float | None = None) -> ControlDecision:
        # Bound elapsed time so a delayed cycle cannot create a large I-term jump.
        now = time.monotonic() if now is None else now
        dt_s = self._period_s if self._last_update is None else self._clamp(
            now - self._last_update, 0.0, 5.0 * self._period_s
        )
        self._last_update = now

        # PI feedback, P reacts to current internal temperature error.
        # ToDo: add derivative term (D term)
        error = setpoint_c - internal_c
        p = self.KP * error

        # Ambient feedforward: anticipate ambient-to-internal heat gain/loss.
        ff = self.KFF * (setpoint_c - ambient_c)

        # I term: accumulate persistent error and clamp its stored magnitude.
        dt_h = dt_s / 3600.0
        next_i = self._clamp(
            self._integral + self.KI_PER_HOUR * error * dt_h,
            -self.INTEGRAL_LIMIT,
            self.INTEGRAL_LIMIT,
        )

        # Conditional anti-windup: do not integrate farther into saturation.
        raw = p + next_i + ff
        if not ((raw > 1.0 and error > 0.0) or
                (raw < -1.0 and error < 0.0)):
            self._integral = next_i

        # Normalize the requested thermal effort: -1=cool, 0=idle, +1=heat.
        effort = self._clamp(p + self._integral + ff, -1.0, 1.0)

        # Relay hysteresis avoids rapid HEAT/COOL/IDLE switching.
        if self._last_action == "HEAT" and effort > self.STOP_THRESHOLD:
            action = "HEAT"
        elif self._last_action == "COOL" and effort < -self.STOP_THRESHOLD:
            action = "COOL"
        elif effort >= self.START_THRESHOLD:
            action = "HEAT"
        elif effort <= -self.START_THRESHOLD:
            action = "COOL"
        else:
            action = "IDLE"
        self._last_action = action

        return ControlDecision(action, effort, error, p, self._integral, ff)


def apply(ct: ChipTool, cfg: Config, action: str) -> None:
    wanted = {
        "HEAT": {cfg.node_plug_heat},
        "COOL": {cfg.node_plug_cool},
        "IDLE": set(),
    }[action]
    nodes = (cfg.node_plug_heat, cfg.node_plug_cool)

    off_failed = False
    for node in nodes:
        if node in wanted:
            continue
        try:
            ct.set_plug(node, False)
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            off_failed = True
            log.warning("plug node %d -> off failed: %s", node, exc)

    if off_failed:
        log.warning("not enabling %s because an actuator OFF command failed", action)
        return

    for node in nodes:
        if node not in wanted:
            continue
        try:
            ct.set_plug(node, True)
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            log.warning("plug node %d -> on failed: %s", node, exc)


def read_gravity(ct: ChipTool, cfg: Config) -> float | None:
    try:
        # Calibration is applied before logging and telemetry.
        return (ct.read_gravity_milli(cfg.node_sensor, cfg.ep_gravity) / 1000.0
                + cfg.sg_offset)
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        log.debug("gravity read failed (shown as n/a): %s", exc)
        return None


def cycle(ct: ChipTool, cfg: Config, em: Emitter,
          controller: ControlModel) -> None:
    try:
        # ToDo: add low-pass-filter
        # Calibrations are applied before control and telemetry.
        ambient_c = (
            ct.read_temp_centi(cfg.node_sensor, cfg.ep_ambient) / 100.0
            + cfg.ambient_offset_c
        )
        internal_c = (
            ct.read_temp_centi(cfg.node_sensor, cfg.ep_internal) / 100.0
            + cfg.internal_offset_c
        )
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        log.warning("sensor read failed, skipping cycle: %s", exc)
        return

    decision = controller.update(
        setpoint_c=cfg.setpoint_c,
        internal_c=internal_c,
        ambient_c=ambient_c,
    )
    diff = round((internal_c - cfg.setpoint_c) * 100)
    apply(ct, cfg, decision.action)
    sg = read_gravity(ct, cfg)

    em.sensor("ambient", ambient_c)
    em.sensor("internal", internal_c)
    if sg is not None:
        em.sensor("gravity", sg)
    em.control(decision.action, diff)
    em.state(ambient_c, internal_c, sg, decision.action)

    log.info(
        "ambient=%.2fC internal=%.2fC setpoint=%.2fC error=%+.2fC "
        "P=%+.3f I=%+.3f FF=%+.3f effort=%+.3f SG=%s -> %s",
        ambient_c, internal_c, cfg.setpoint_c, decision.error_c,
        decision.p_term, decision.i_term, decision.feedforward_term,
        decision.effort, f"{sg:.3f}" if sg is not None else "n/a",
        decision.action,
    )


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )
    cfg_path = Path(sys.argv[1] if len(sys.argv) > 1
                    else Path(__file__).with_name("config.yaml"))
    try:
        cfg = Config.load(cfg_path)
    except (OSError, KeyError, TypeError, ValueError, RuntimeError) as exc:
        log.error("configuration error: %s", exc)
        return 2
    controller = ControlModel(cfg.period_s)
    ct, em = ChipTool(cfg), Emitter(cfg)
    log.info(
        "control loop: setpoint=%.2fC ambient_offset=%+.2fC "
        "internal_offset=%+.2fC sg_offset=%+.3f period=%ds config=%s",
        cfg.setpoint_c, cfg.ambient_offset_c, cfg.internal_offset_c, cfg.sg_offset,
        cfg.period_s, cfg_path,
    )
    while True:
        start = time.monotonic()
        cycle(ct, cfg, em, controller)
        time.sleep(max(0.0, cfg.period_s - (time.monotonic() - start)))


if __name__ == "__main__":
    sys.exit(main())
