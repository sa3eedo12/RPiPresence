#!/usr/bin/env python3
"""RPiPresence - Keep the display on while the motion sensor detects presence.

Monitors a GPIO-connected motion/presence sensor (e.g. HC-SR501 PIR) on a
Raspberry Pi running emteriaOS.  The display stays on as long as motion is
detected and turns off after a configurable idle timeout.
"""

import configparser
import logging
import os
import signal
import subprocess
import sys
import time
from abc import ABC, abstractmethod
from pathlib import Path

logger = logging.getLogger("rpi_presence")

# ---------------------------------------------------------------------------
# GPIO readers
# ---------------------------------------------------------------------------

class GPIOReader(ABC):
    """Abstract base class for reading a GPIO pin."""

    @abstractmethod
    def read(self) -> bool:
        """Return *True* when the sensor signals motion / presence."""

    @abstractmethod
    def cleanup(self) -> None:
        """Release any resources held by the reader."""


class GpiodReader(GPIOReader):
    """Read a GPIO pin using the *gpiod* (libgpiod ≥ 2) Python bindings."""

    def __init__(self, chip: str, pin: int) -> None:
        import gpiod  # type: ignore[import-untyped]
        from gpiod.line import Direction  # type: ignore[import-untyped]

        self._chip = gpiod.Chip(chip)
        self._request = self._chip.request_lines(
            config={pin: gpiod.LineSettings(direction=Direction.INPUT)},
        )
        self._pin = pin
        logger.info("GpiodReader: opened %s line %d", chip, pin)

    def read(self) -> bool:
        return bool(self._request.get_value(self._pin))

    def cleanup(self) -> None:
        self._request.release()
        self._chip.close()
        logger.debug("GpiodReader: cleaned up")


class SysfsGPIOReader(GPIOReader):
    """Read a GPIO pin through the legacy sysfs interface."""

    def __init__(self, pin: int) -> None:
        self._pin = pin
        self._value_path = Path(f"/sys/class/gpio/gpio{pin}/value")
        if not self._value_path.exists():
            Path("/sys/class/gpio/export").write_text(str(pin))
            time.sleep(0.1)
            Path(f"/sys/class/gpio/gpio{pin}/direction").write_text("in")
        logger.info("SysfsGPIOReader: using /sys/class/gpio/gpio%d", pin)

    def read(self) -> bool:
        return self._value_path.read_text().strip() == "1"

    def cleanup(self) -> None:
        try:
            Path("/sys/class/gpio/unexport").write_text(str(self._pin))
        except OSError:
            pass
        logger.debug("SysfsGPIOReader: cleaned up")


class RPiGPIOReader(GPIOReader):
    """Read a GPIO pin using the *RPi.GPIO* library."""

    def __init__(self, pin: int) -> None:
        import RPi.GPIO as GPIO  # type: ignore[import-untyped]

        self._GPIO = GPIO
        self._pin = pin
        GPIO.setmode(GPIO.BCM)
        GPIO.setup(pin, GPIO.IN)
        logger.info("RPiGPIOReader: BCM pin %d", pin)

    def read(self) -> bool:
        return bool(self._GPIO.input(self._pin))

    def cleanup(self) -> None:
        self._GPIO.cleanup(self._pin)
        logger.debug("RPiGPIOReader: cleaned up")


def create_gpio_reader(method: str, chip: str, pin: int) -> GPIOReader:
    """Instantiate a *GPIOReader* based on the chosen *method*.

    When *method* is ``"auto"``, each backend is tried in order:
    gpiod → sysfs → RPi.GPIO.
    """
    order: list[str]
    if method == "auto":
        order = ["gpiod", "sysfs", "rpigpio"]
    else:
        order = [method]

    last_err: Exception | None = None
    for name in order:
        try:
            if name == "gpiod":
                return GpiodReader(chip, pin)
            if name == "sysfs":
                return SysfsGPIOReader(pin)
            if name == "rpigpio":
                return RPiGPIOReader(pin)
            raise ValueError(f"Unknown GPIO method: {name!r}")
        except Exception as exc:  # noqa: BLE001
            logger.debug("GPIO method %r unavailable: %s", name, exc)
            last_err = exc

    raise RuntimeError(
        f"No working GPIO method found (tried {order})"
    ) from last_err


# ---------------------------------------------------------------------------
# Display controllers
# ---------------------------------------------------------------------------

class DisplayController(ABC):
    """Abstract base class for turning the display on / off."""

    @abstractmethod
    def turn_on(self) -> None: ...

    @abstractmethod
    def turn_off(self) -> None: ...


class BacklightController(DisplayController):
    """Control the official RPi touchscreen backlight via sysfs."""

    def __init__(self, backlight_path: str) -> None:
        self._power = Path(backlight_path) / "bl_power"
        if not self._power.exists():
            raise FileNotFoundError(self._power)
        logger.info("BacklightController: %s", self._power)

    def turn_on(self) -> None:
        self._power.write_text("0")  # 0 = on for bl_power
        logger.debug("Backlight ON")

    def turn_off(self) -> None:
        self._power.write_text("1")  # 1 = off for bl_power
        logger.debug("Backlight OFF")


class AndroidController(DisplayController):
    """Control the screen on emteriaOS (Android) via *input keyevent*.

    This works by simulating a power-button press to wake/sleep the device
    and querying the current display state via dumpsys.
    """

    def __init__(self) -> None:
        if not _command_exists("input"):
            raise FileNotFoundError("'input' command not found (not Android?)")
        logger.info("AndroidController: using input keyevent")

    def _is_screen_on(self) -> bool:
        result = subprocess.run(
            ["dumpsys", "power"],
            capture_output=True,
            text=True,
            check=False,
        )
        return "mWakefulness=Awake" in result.stdout

    def turn_on(self) -> None:
        if not self._is_screen_on():
            subprocess.run(
                ["input", "keyevent", "KEYCODE_WAKEUP"],
                check=True,
                capture_output=True,
            )
            logger.debug("Android screen ON")

    def turn_off(self) -> None:
        if self._is_screen_on():
            subprocess.run(
                ["input", "keyevent", "KEYCODE_SLEEP"],
                check=True,
                capture_output=True,
            )
            logger.debug("Android screen OFF")


def _command_exists(cmd: str) -> bool:
    """Return *True* if *cmd* is on ``$PATH``."""
    from shutil import which

    return which(cmd) is not None


def create_display_controller(
    method: str,
    backlight_path: str,
) -> DisplayController:
    """Instantiate a *DisplayController* based on the chosen *method*.

    When *method* is ``"auto"``, each backend is tried in order:
    backlight → android.
    """
    order: list[str]
    if method == "auto":
        order = ["backlight", "android"]
    else:
        order = [method]

    last_err: Exception | None = None
    for name in order:
        try:
            if name == "backlight":
                return BacklightController(backlight_path)
            if name == "android":
                return AndroidController()
            raise ValueError(f"Unknown display method: {name!r}")
        except Exception as exc:  # noqa: BLE001
            logger.debug("Display method %r unavailable: %s", name, exc)
            last_err = exc

    raise RuntimeError(
        f"No working display method found (tried {order})"
    ) from last_err


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def _load_config(path: str) -> configparser.ConfigParser:
    config = configparser.ConfigParser()
    config.read(path)
    return config


def run(config_path: str = "config.ini") -> None:  # noqa: C901
    """Entry point: load config, initialise hardware, and start the loop."""

    config = _load_config(config_path)

    # -- Logging --
    log_level = config.get("logging", "level", fallback="INFO").upper()
    logging.basicConfig(
        level=getattr(logging, log_level, logging.INFO),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    # -- Sensor --
    gpio_pin = config.getint("sensor", "gpio_pin", fallback=17)
    gpio_method = config.get("sensor", "gpio_method", fallback="auto")
    gpio_chip = config.get("sensor", "gpio_chip", fallback="gpiochip0")
    reader = create_gpio_reader(gpio_method, gpio_chip, gpio_pin)

    # -- Display --
    display_method = config.get("display", "method", fallback="auto")
    backlight_path = config.get(
        "display", "backlight_path",
        fallback="/sys/class/backlight/rpi_backlight",
    )
    display = create_display_controller(display_method, backlight_path)

    # -- Timing --
    timeout = config.getfloat("timing", "timeout", fallback=60)
    poll_interval = config.getfloat("timing", "poll_interval", fallback=0.5)
    cooldown = config.getfloat("timing", "cooldown", fallback=10)

    logger.info(
        "Starting RPiPresence (pin=%d, timeout=%.1fs, poll=%.1fs, cooldown=%.1fs)",
        gpio_pin,
        timeout,
        poll_interval,
        cooldown,
    )

    # Graceful shutdown
    running = True

    def _shutdown(signum: int, _frame: object) -> None:
        nonlocal running
        logger.info("Received signal %d – shutting down", signum)
        running = False

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    display_on = True
    display.turn_on()
    last_motion_time = time.monotonic()
    last_off_time: float = 0.0

    try:
        while running:
            motion = reader.read()

            if motion:
                last_motion_time = time.monotonic()
                if not display_on:
                    elapsed = time.monotonic() - last_off_time
                    if elapsed < cooldown:
                        logger.debug(
                            "Cooldown active — ignoring motion (%.0fs remaining)",
                            cooldown - elapsed,
                        )
                    else:
                        logger.info("Motion detected – turning display ON")
                        display.turn_on()
                        display_on = True
            elif display_on and (time.monotonic() - last_motion_time) >= timeout:
                logger.info("No motion for %.0fs – turning display OFF", timeout)
                display.turn_off()
                display_on = False
                last_off_time = time.monotonic()

            time.sleep(poll_interval)
    finally:
        reader.cleanup()
        logger.info("RPiPresence stopped")


def main() -> None:
    """CLI wrapper that accepts an optional config file path."""
    config_path = sys.argv[1] if len(sys.argv) > 1 else "config.ini"
    if not Path(config_path).exists():
        logger.warning("Config file %r not found – using defaults", config_path)
    run(config_path)


if __name__ == "__main__":
    main()
