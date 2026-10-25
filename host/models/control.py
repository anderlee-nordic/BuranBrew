"""PI control, time-proportional actuation.

                       ControlLoop
                      /           \
               update()          set_effort()/tick()
                  v                    v
            PIController --effort--> TimeProportionalActuator
                             (via ControlLoop)
"""

from __future__ import annotations

import logging
import math
import subprocess
import time
from dataclasses import dataclass

from utils import ChipTool, Config, Emitter

log = logging.getLogger("buranbrew")


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(value, high))


def ema(previous: float | None, sample: float, alpha: float) -> float:
    return sample if previous is None else previous + alpha * (sample - previous)


@dataclass(frozen=True)
class ControlDecision:
    effort: float
    error_c: float
    p_term: float
    i_term: float
    feedforward_term: float


class PIController:
    """
    Produce normalized thermal effort in [-1, +1].

    Positive effort requests heating and negative effort requests cooling.
    Magnitude is the requested duty cycle; e.g. +0.30 means 30% HEAT.
    """

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.integral = 0.0
        self.last_update: float | None = None

    def update(self, *, internal_c: float, ambient_c: float,
               now: float | None = None) -> ControlDecision:
        now = time.monotonic() if now is None else now
        t = self.cfg.control
        dt = self.cfg.period_s if self.last_update is None else clamp(
            now - self.last_update, 0.0, t.integral_dt_max_s
        )
        self.last_update = now

        error = self.cfg.setpoint_c - internal_c
        p = t.kp * error
        ff = t.kff * (self.cfg.setpoint_c - ambient_c)
        candidate = clamp(
            self.integral + t.ki_per_hour * error * dt / 3600.0,
            -t.integral_limit, t.integral_limit,
        )
        raw = p + candidate + ff
        if not ((raw > 1 and error > 0) or (raw < -1 and error < 0)):
            self.integral = candidate
        return ControlDecision(clamp(p + self.integral + ff, -1, 1),
                               error, p, self.integral, ff)


@dataclass(frozen=True)
class ActuatorPlan:
    requested_action: str
    effort: float
    duty_cycle: float
    active_s: float
    window_s: float
    reason: str


@dataclass(frozen=True)
class ActuatorTransition:
    action: str
    plan: ActuatorPlan


class TimeProportionalActuator:
    """
    Convert PI effort into non-blocking HEAT/COOL ON time.

    E.g., with window_s=600, effort=+0.30 means HEAT during the first
    180 seconds of each 600-second window and IDLE for the remaining 420.
    """

    def __init__(self, chip: ChipTool, cfg: Config):
        self.chip, self.cfg = chip, cfg
        self._action = "IDLE"
        self.effort = 0.0
        self.last_command: float | None = None
        self.window_start: float | None = None
        self.window_direction: str | None = None
        self.last_active: str | None = None
        self.idle_since: float | None = None

    @property
    def action(self) -> str:
        return self._action

    def initialize(self, now: float) -> ActuatorTransition:
        if not self._switch("IDLE"):
            raise RuntimeError("failed to force actuators to IDLE at startup")
        self.window_start = self.idle_since = now
        return ActuatorTransition("IDLE", self._plan("IDLE", "startup"))

    def set_effort(self, effort: float, now: float) -> None:
        stale = (self.last_command is None or
                 now - self.last_command > self.cfg.control.command_stale_timeout_s)
        if stale:
            self.window_start = now
        self.last_command = now
        self.effort = clamp(effort, -1, 1)
        if self.window_direction is None and self.effort:
            self.window_direction = "HEAT" if self.effort > 0 else "COOL"

    def _plan(self, action: str, reason: str, duty: float = 0.0,
              active: float = 0.0) -> ActuatorPlan:
        return ActuatorPlan(action, self.effort, duty, active,
                            self.cfg.control.window_s, reason)

    def plan(self, now: float) -> ActuatorPlan:
        """Calculate the requested state"""
        t = self.cfg.control
        if self.window_start is None:
            self.window_start = now
        elapsed = now - self.window_start
        if elapsed >= t.window_s:
            self.window_start += math.floor(elapsed / t.window_s) * t.window_s

        if self.last_command is None:
            return self._plan("IDLE", "no-command")
        if now - self.last_command > t.command_stale_timeout_s:
            return self._plan("IDLE", "stale-command")
        duty = abs(self.effort)
        if duty <= t.effort_deadband:
            return self._plan("IDLE", "deadband")

        direction = "HEAT" if self.effort > 0 else "COOL"
        active = duty * t.window_s
        minimum = t.heat_min_on_s if direction == "HEAT" else t.cool_min_on_s
        if active < minimum:
            return self._plan("IDLE", "below-min-pulse", duty, active)

        reversing = (self._action != "IDLE" and self._action != direction)
        waiting = (self.last_active is not None and direction != self.last_active
                   and self.idle_since is not None
                   and now - self.idle_since < t.reverse_idle_s)
        if reversing or waiting:
            return self._plan("IDLE", "reverse-lockout", duty, active)
        if direction == self.window_direction and now - self.window_start >= active:
            return self._plan("IDLE", "duty-off", duty, active)
        return self._plan(direction, "duty-on", duty, active)

    def tick(self, now: float) -> ActuatorTransition | None:
        plan = self.plan(now)
        target = plan.requested_action
        if target == self._action or not self._switch(target):
            return None
        if target != "IDLE" and target != self.window_direction:
            self.window_start, self.window_direction = now, target
        self._record(target, now)
        return ActuatorTransition(target, plan)

    def force_idle(self, now: float, reason: str = "shutdown") -> ActuatorTransition | None:
        if self._action == "IDLE" or not self._switch("IDLE"):
            return None
        self._record("IDLE", now)
        return ActuatorTransition("IDLE", self._plan("IDLE", reason))

    def _record(self, target: str, now: float) -> None:
        if self._action != "IDLE" and target != self._action:
            self.last_active = self._action
            self.idle_since = now if target == "IDLE" else None
        elif self._action == "IDLE" and target != "IDLE":
            self.idle_since = None
        self._action = target

    def _switch(self, target: str) -> bool:
        """COOL and HEAT ON states are mutually exclusive"""
        heat, cool = self.cfg.node_plug_heat, self.cfg.node_plug_cool
        wanted = {"HEAT": heat, "COOL": cool, "IDLE": None}[target]
        failed = False
        for node in (heat, cool):
            if node == wanted:
                continue
            try:
                self.chip.set_plug(node, False)
            except (RuntimeError, subprocess.TimeoutExpired) as exc:
                failed = True
                log.warning("plug node %d -> off failed: %s", node, exc)
        if failed:
            log.warning("not enabling %s because an actuator OFF command failed", target)
            return False
        if wanted is not None:
            try:
                self.chip.set_plug(wanted, True)
            except (RuntimeError, subprocess.TimeoutExpired) as exc:
                log.warning("plug node %d -> on failed: %s", wanted, exc)
                return False
        return True


@dataclass(frozen=True)
class Temperatures:
    ambient_c: float
    internal_c: float


class ControlLoop:
    """Read sensors periodically while actuator timing advances independently."""

    def __init__(self, cfg: Config, chip: ChipTool, telemetry: Emitter,
                 controller: PIController, actuator: TimeProportionalActuator):
        self.cfg, self.chip, self.telemetry = cfg, chip, telemetry
        self.controller, self.actuator = controller, actuator
        self.filtered: Temperatures | None = None
        self.diff_centi = 0

    def _read_temperatures(self) -> Temperatures | None:
        try:
            return Temperatures(
                self.chip.read_temp_centi(self.cfg.node_sensor, self.cfg.ep_ambient) / 100
                + self.cfg.ambient_offset_c,
                self.chip.read_temp_centi(self.cfg.node_sensor, self.cfg.ep_internal) / 100
                + self.cfg.internal_offset_c,
            )
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            log.warning("sensor read failed, retaining previous effort: %s", exc)
            return None

    def _read_gravity(self) -> float | None:
        try:
            return (self.chip.read_gravity_milli(self.cfg.node_sensor, self.cfg.ep_gravity)
                    / 1000 + self.cfg.sg_offset)
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            log.debug("gravity read failed (shown as n/a): %s", exc)
            return None

    def _emit_control(self, action: str, plan: ActuatorPlan, reason: str) -> None:
        self.telemetry.control(
            action=action,
            diff_centi=self.diff_centi,
            effort=plan.effort,
            duty_cycle=plan.duty_cycle,
            active_s=plan.active_s,
            window_s=plan.window_s,
            reason=reason
        )

    def _transition(self, transition: ActuatorTransition | None) -> None:
        if transition is None:
            return
        plan = transition.plan
        self._emit_control(transition.action, plan, plan.reason)
        log.info("actuator -> %s reason=%s effort=%+.3f duty=%.1f%% active=%.0fs/%.0fs",
                 transition.action, plan.reason, plan.effort,
                 plan.duty_cycle * 100, plan.active_s, plan.window_s)

    def _tick(self, now: float) -> None:
        self._transition(self.actuator.tick(now))

    def _control_update(self) -> None:
        """Read sensors, update PI, apply duty scheduling, then report."""
        raw = self._read_temperatures()
        if raw is None:
            return
        t = self.cfg.control
        previous = self.filtered
        self.filtered = Temperatures(
            ema(None if previous is None else previous.ambient_c,
                raw.ambient_c, t.ambient_filter_alpha),
            ema(None if previous is None else previous.internal_c,
                raw.internal_c, t.internal_filter_alpha),
        )

        now = time.monotonic()
        decision = self.controller.update(
            internal_c=self.filtered.internal_c,
            ambient_c=self.filtered.ambient_c,
            now=now,
        )
        self.diff_centi = round((raw.internal_c - self.cfg.setpoint_c) * 100)
        self.actuator.set_effort(decision.effort, now)
        self._tick(now)

        sg = self._read_gravity()
        now = time.monotonic()
        self._tick(now)  # recheck timing
        self._report(raw, decision, sg, self.actuator.plan(now))

    def _report(self, raw: Temperatures, decision: ControlDecision,
                sg: float | None, plan: ActuatorPlan) -> None:
        """Emit the periodic heartbeat, calibrated readings, state, and log."""
        self._emit_control(self.actuator.action, plan, "heartbeat")
        for metric, value in (("ambient", raw.ambient_c), ("internal", raw.internal_c)):
            self.telemetry.sensor(metric, value)
        if sg is not None:
            self.telemetry.sensor("gravity", sg)
        self.telemetry.state(
            ambient=raw.ambient_c,
            internal=raw.internal_c,
            sg=sg,
            action=self.actuator.action,
            effort=decision.effort
        )
        log.info(
            "ambient=%.2fC(ema=%.2f) internal=%.2fC(ema=%.2f) "
            "setpoint=%.2fC error=%+.2fC P=%+.3f I=%+.3f FF=%+.3f "
            "effort=%+.3f plan=%s %.1f%% %.0fs/%.0fs actual=%s SG=%s",
            raw.ambient_c, self.filtered.ambient_c,
            raw.internal_c, self.filtered.internal_c,
            self.cfg.setpoint_c, decision.error_c,
            decision.p_term, decision.i_term, decision.feedforward_term,
            decision.effort, plan.requested_action, plan.duty_cycle * 100,
            plan.active_s, plan.window_s, self.actuator.action,
            f"{sg:.3f}" if sg is not None else "n/a",
        )

    def run(self) -> None:
        now = time.monotonic()
        self._transition(self.actuator.initialize(now))
        next_update = now
        try:
            while True:
                now = time.monotonic()
                self._tick(now)
                if now >= next_update:
                    self._control_update()
                    next_update = time.monotonic() + self.cfg.period_s
                time.sleep(self.cfg.control.actuator_tick_s)
        finally:
            self._transition(self.actuator.force_idle(time.monotonic()))
