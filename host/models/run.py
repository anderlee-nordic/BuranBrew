#!/usr/bin/env python3
"""BuranBrew control model entry point."""

from __future__ import annotations

import logging
import sys
from pathlib import Path

from control import ControlLoop, PIController, TimeProportionalActuator
from utils import ChipTool, Config, Emitter


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )
    log = logging.getLogger("buranbrew")
    cfg_path = Path(
        sys.argv[1] if len(sys.argv) > 1 else Path(__file__).with_name("config.yaml")
    )

    try:
        cfg = Config.load(cfg_path)
    except (OSError, KeyError, TypeError, ValueError, RuntimeError) as exc:
        log.error("configuration error: %s", exc)
        return 2

    chip = ChipTool(cfg)
    telemetry = Emitter(cfg)
    controller = PIController(cfg)
    actuator = TimeProportionalActuator(chip, cfg)
    loop = ControlLoop(cfg, chip, telemetry, controller, actuator)

    log.info(
        "control loop: setpoint=%.2fC period=%.0fs window=%.0fs deadband=%.3f config=%s",
        cfg.setpoint_c,
        cfg.period_s,
        cfg.control.window_s,
        cfg.control.effort_deadband,
        cfg_path,
    )

    try:
        loop.run()
    except KeyboardInterrupt:
        log.info("control loop stopped")
        return 0
    except RuntimeError as exc:
        log.error("control loop fatal error: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

