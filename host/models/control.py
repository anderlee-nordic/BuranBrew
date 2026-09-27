"""PI control, time-proportional actuation"""

from __future__ import annotations

import logging
import math
import subprocess
import time
from dataclasses import dataclass

from utils import ChipTool, Config, Emitter

log = logging.getLogger("buranbrew")


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
        self._cfg = cfg
        self._integral = 0.0
        self._last_update: float | None = None

    @staticmethod
    def _clamp(value: float, low: float, high: float) -> float:
        return max(low, min(high, value))

    def update(
        self,
        *,
        internal_c: float,
        ambient_c: float,
        now: float | None = None,
    ) -> ControlDecision:
        now = time.monotonic() if now is None else now
        tuning = self._cfg.control

        if self._last_update is None:
            dt_s = self._cfg.period_s
        else:
            dt_s = self._clamp(
                now - self._last_update,
                0.0,
                tuning.integral_dt_max_s,
            )
        self._last_update = now

        error = self._cfg.setpoint_c - internal_c
        p = tuning.kp * error
        ff = tuning.kff * (self._cfg.setpoint_c - ambient_c)

        candidate_i = self._clamp(
            self._integral
            + tuning.ki_per_hour * error * (dt_s / 3600.0),
            -tuning.integral_limit,
            tuning.integral_limit,
        )

        candidate_raw = p + candidate_i + ff
        driving_farther_into_saturation = (
            (candidate_raw > 1.0 and error > 0.0)
            or (candidate_raw < -1.0 and error < 0.0)
        )
        if not driving_farther_into_saturation:
            self._integral = candidate_i

        effort = self._clamp(p + self._integral + ff, -1.0, 1.0)
        return ControlDecision(
            effort=effort,
            error_c=error,
            p_term=p,
            i_term=self._integral,
            feedforward_term=ff,
        )


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
        self._chip = chip
        self._cfg = cfg
        self._effort = 0.0
        self._last_effort_update: float | None = None
        self._window_start: float | None = None
        self._action = "IDLE"
        self._last_active_direction: str | None = None
        self._idle_since: float | None = None

    @property
    def action(self) -> str:
        return self._action

    def initialize(self, now: float) -> ActuatorTransition:
        if not self._switch("IDLE"):
            raise RuntimeError("failed to force actuators to IDLE at startup")
        self._window_start = now
        self._idle_since = now
        plan = ActuatorPlan(
            "IDLE", 0.0, 0.0, 0.0, self._cfg.control.window_s, "startup"
        )
        return ActuatorTransition("IDLE", plan)

    def set_effort(self, effort: float, now: float) -> None:
        effort = max(-1.0, min(1.0, effort))
        timeout = self._cfg.control.command_stale_timeout_s
        was_stale = (
            self._last_effort_update is None
            or now - self._last_effort_update > timeout
        )
        if was_stale:
            # A recovered controller begins a fresh proportional-output window.
            self._window_start = now
        self._effort = effort
        self._last_effort_update = now

    def _advance_window(self, now: float) -> None:
        window_s = self._cfg.control.window_s
        if self._window_start is None:
            self._window_start = now
            return
        elapsed = now - self._window_start
        if elapsed >= window_s:
            self._window_start += math.floor(elapsed / window_s) * window_s

    def plan(self, now: float) -> ActuatorPlan:
        tuning = self._cfg.control
        self._advance_window(now)

        if self._last_effort_update is None:
            return ActuatorPlan(
                "IDLE", 0.0, 0.0, 0.0, tuning.window_s, "no-command"
            )

        if now - self._last_effort_update > tuning.command_stale_timeout_s:
            return ActuatorPlan(
                "IDLE", self._effort, 0.0, 0.0, tuning.window_s, "stale-command"
            )

        magnitude = abs(self._effort)
        if magnitude <= tuning.effort_deadband:
            return ActuatorPlan(
                "IDLE", self._effort, 0.0, 0.0, tuning.window_s, "deadband"
            )

        direction = "HEAT" if self._effort > 0.0 else "COOL"
        active_s = magnitude * tuning.window_s
        min_on_s = (
            tuning.heat_min_on_s if direction == "HEAT" else tuning.cool_min_on_s
        )
        if active_s < min_on_s:
            return ActuatorPlan(
                "IDLE",
                self._effort,
                magnitude,
                active_s,
                tuning.window_s,
                "below-min-pulse",
            )

        assert self._window_start is not None
        elapsed = now - self._window_start
        requested = direction if elapsed < active_s else "IDLE"
        reason = "duty-on" if requested != "IDLE" else "duty-off"

        # Don't reverse directly from HEAT to COOL or vice versa. First turn
        # everything OFF (IDLE), then wait reverse_idle_s before the new output.
        if requested in ("HEAT", "COOL"):
            if self._action in ("HEAT", "COOL") and requested != self._action:
                requested = "IDLE"
                reason = "reverse-lockout"
            elif (
                self._last_active_direction is not None
                and requested != self._last_active_direction
                and self._idle_since is not None
                and now - self._idle_since < tuning.reverse_idle_s
            ):
                requested = "IDLE"
                reason = "reverse-lockout"

        return ActuatorPlan(
            requested_action=requested,
            effort=self._effort,
            duty_cycle=magnitude,
            active_s=active_s,
            window_s=tuning.window_s,
            reason=reason,
        )

    def tick(self, now: float) -> ActuatorTransition | None:
        plan = self.plan(now)
        wanted = plan.requested_action
        if wanted == self._action:
            return None

        previous = self._action
        if not self._switch(wanted):
            return None

        if previous in ("HEAT", "COOL") and wanted != previous:
            self._last_active_direction = previous
            self._idle_since = now if wanted == "IDLE" else None
        elif previous == "IDLE" and wanted in ("HEAT", "COOL"):
            self._idle_since = None

        self._action = wanted
        return ActuatorTransition(wanted, plan)

    def force_idle(
        self, now: float, reason: str = "shutdown"
    ) -> ActuatorTransition | None:
        if self._action == "IDLE":
            return None
        previous = self._action
        if not self._switch("IDLE"):
            return None
        self._last_active_direction = previous
        self._idle_since = now
        self._action = "IDLE"
        plan = ActuatorPlan(
            "IDLE",
            self._effort,
            0.0,
            0.0,
            self._cfg.control.window_s,
            reason,
        )
        return ActuatorTransition("IDLE", plan)

    def _switch(self, action: str) -> bool:
        wanted = {
            "HEAT": {self._cfg.node_plug_heat},
            "COOL": {self._cfg.node_plug_cool},
            "IDLE": set(),
        }[action]
        nodes = (self._cfg.node_plug_heat, self._cfg.node_plug_cool)

        off_failed = False
        for node in nodes:
            if node in wanted:
                continue
            try:
                self._chip.set_plug(node, False)
            except (RuntimeError, subprocess.TimeoutExpired) as exc:
                off_failed = True
                log.warning("plug node %d -> off failed: %s", node, exc)

        if off_failed:
            log.warning("not enabling %s because an actuator OFF command failed", action)
            return False

        for node in wanted:
            try:
                self._chip.set_plug(node, True)
            except (RuntimeError, subprocess.TimeoutExpired) as exc:
                log.warning("plug node %d -> on failed: %s", node, exc)
                return False
        return True


class ControlLoop:
    """Read sensors periodically while actuator timing advances independently."""

    def __init__(
        self,
        cfg: Config,
        chip: ChipTool,
        telemetry: Emitter,
        controller: PIController,
        actuator: TimeProportionalActuator,
    ):
        self._cfg = cfg
        self._chip = chip
        self._telemetry = telemetry
        self._controller = controller
        self._actuator = actuator
        self._ambient_filtered: float | None = None
        self._internal_filtered: float | None = None
        self._last_diff_centi = 0

    @staticmethod
    def _ema(previous: float | None, sample: float, alpha: float) -> float:
        if previous is None:
            return sample
        return previous + alpha * (sample - previous)

    def _read_gravity(self) -> float | None:
        try:
            return (
                self._chip.read_gravity_milli(
                    self._cfg.node_sensor, self._cfg.ep_gravity
                )
                / 1000.0
                + self._cfg.sg_offset
            )
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            log.debug("gravity read failed (shown as n/a): %s", exc)
            return None

    def _emit_transition(self, transition: ActuatorTransition) -> None:
        plan = transition.plan
        self._telemetry.control(
            action=transition.action,
            diff_centi=self._last_diff_centi,
            effort=plan.effort,
            duty_cycle=plan.duty_cycle,
            active_s=plan.active_s,
            window_s=plan.window_s,
            reason=plan.reason,
        )
        log.info(
            "actuator -> %s reason=%s effort=%+.3f duty=%.1f%% active=%.0fs/%.0fs",
            transition.action,
            plan.reason,
            plan.effort,
            plan.duty_cycle * 100.0,
            plan.active_s,
            plan.window_s,
        )

    def _emit_control_heartbeat(self, plan: ActuatorPlan) -> None:
        """Refresh control telemetry even when the actuator state is unchanged."""
        self._telemetry.control(
            action=self._actuator.action,
            diff_centi=self._last_diff_centi,
            effort=plan.effort,
            duty_cycle=plan.duty_cycle,
            active_s=plan.active_s,
            window_s=plan.window_s,
            reason="heartbeat",
        )

    def _control_update(self, now: float) -> None:
        try:
            ambient_c = (
                self._chip.read_temp_centi(
                    self._cfg.node_sensor, self._cfg.ep_ambient
                )
                / 100.0
                + self._cfg.ambient_offset_c
            )
            internal_c = (
                self._chip.read_temp_centi(
                    self._cfg.node_sensor, self._cfg.ep_internal
                )
                / 100.0
                + self._cfg.internal_offset_c
            )
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            log.warning("sensor read failed, retaining previous effort: %s", exc)
            return

        # Re-sample monotonic time after chip-tool calls, which can be slow.
        now = time.monotonic()
        tuning = self._cfg.control
        self._ambient_filtered = self._ema(
            self._ambient_filtered, ambient_c, tuning.ambient_filter_alpha
        )
        self._internal_filtered = self._ema(
            self._internal_filtered, internal_c, tuning.internal_filter_alpha
        )

        decision = self._controller.update(
            internal_c=self._internal_filtered,
            ambient_c=self._ambient_filtered,
            now=now,
        )
        self._last_diff_centi = round(
            (internal_c - self._cfg.setpoint_c) * 100.0
        )

        self._actuator.set_effort(decision.effort, now)
        transition = self._actuator.tick(now)
        if transition is not None:
            self._emit_transition(transition)

        # SG is telemetry-only and does not participate in the controller.
        sg = self._read_gravity()
        now = time.monotonic()
        transition = self._actuator.tick(now)
        if transition is not None:
            self._emit_transition(transition)

        plan = self._actuator.plan(now)
        self._emit_control_heartbeat(plan)
        self._telemetry.sensor("ambient", ambient_c)
        self._telemetry.sensor("internal", internal_c)
        if sg is not None:
            self._telemetry.sensor("gravity", sg)
        self._telemetry.state(
            ambient=ambient_c,
            internal=internal_c,
            sg=sg,
            action=self._actuator.action,
            effort=decision.effort,
        )

        log.info(
            "ambient=%.2fC(ema=%.2f) internal=%.2fC(ema=%.2f) "
            "setpoint=%.2fC error=%+.2fC P=%+.3f I=%+.3f FF=%+.3f "
            "effort=%+.3f plan=%s %.1f%% %.0fs/%.0fs actual=%s SG=%s",
            ambient_c,
            self._ambient_filtered,
            internal_c,
            self._internal_filtered,
            self._cfg.setpoint_c,
            decision.error_c,
            decision.p_term,
            decision.i_term,
            decision.feedforward_term,
            decision.effort,
            plan.requested_action,
            plan.duty_cycle * 100.0,
            plan.active_s,
            plan.window_s,
            self._actuator.action,
            f"{sg:.3f}" if sg is not None else "n/a",
        )

    def run(self) -> None:
        now = time.monotonic()
        self._emit_transition(self._actuator.initialize(now))
        next_sensor_update = now

        try:
            while True:
                now = time.monotonic()
                transition = self._actuator.tick(now)
                if transition is not None:
                    self._emit_transition(transition)

                if now >= next_sensor_update:
                    self._control_update(now)
                    # Avoid catch-up bursts after slow chip-tool calls.
                    next_sensor_update = time.monotonic() + self._cfg.period_s

                time.sleep(self._cfg.control.actuator_tick_s)
        finally:
            transition = self._actuator.force_idle(time.monotonic())
            if transition is not None:
                self._emit_transition(transition)

