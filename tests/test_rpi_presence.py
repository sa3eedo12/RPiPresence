"""Tests for RPiPresence core logic."""

import configparser
import unittest
from unittest.mock import MagicMock, patch

import rpi_presence


class TestCreateGPIOReader(unittest.TestCase):
    """Verify the factory falls back through backends correctly."""

    def test_unknown_method_raises(self):
        with self.assertRaises(RuntimeError):
            rpi_presence.create_gpio_reader("bogus", "gpiochip0", 17)

    @patch.dict("sys.modules", {"gpiod": None, "RPi": None, "RPi.GPIO": None})
    def test_auto_falls_through_when_all_fail(self):
        """When no backend is available the factory raises RuntimeError."""
        with self.assertRaises(RuntimeError):
            rpi_presence.create_gpio_reader("auto", "gpiochip0", 17)


class TestCreateDisplayController(unittest.TestCase):
    """Verify the display controller factory."""

    def test_unknown_method_raises(self):
        with self.assertRaises(RuntimeError):
            rpi_presence.create_display_controller("bogus", "/nonexistent")

    def test_backlight_missing_path_raises(self):
        with self.assertRaises(RuntimeError):
            rpi_presence.create_display_controller(
                "backlight", "/nonexistent/backlight"
            )


class TestSysfsGPIOReader(unittest.TestCase):
    """Test the sysfs GPIO reader with mocked paths."""

    def test_read_returns_true_on_high(self):
        mock_value = MagicMock()
        mock_value.read_text.return_value = "1\n"

        reader = rpi_presence.SysfsGPIOReader.__new__(rpi_presence.SysfsGPIOReader)
        reader._pin = 17
        reader._value_path = mock_value

        self.assertTrue(reader.read())

    def test_read_returns_false_on_low(self):
        mock_value = MagicMock()
        mock_value.read_text.return_value = "0\n"

        reader = rpi_presence.SysfsGPIOReader.__new__(rpi_presence.SysfsGPIOReader)
        reader._pin = 17
        reader._value_path = mock_value

        self.assertFalse(reader.read())


class TestAndroidController(unittest.TestCase):
    """Test the Android display controller."""

    @patch("rpi_presence._command_exists", return_value=True)
    @patch("subprocess.run")
    def test_turn_on_when_screen_off(self, mock_run, _mock_cmd):
        mock_run.return_value = MagicMock(stdout="mWakefulness=Asleep", returncode=0)
        ctrl = rpi_presence.AndroidController()
        ctrl.turn_on()
        # Should call dumpsys then keyevent
        self.assertEqual(mock_run.call_count, 2)

    @patch("rpi_presence._command_exists", return_value=True)
    @patch("subprocess.run")
    def test_turn_on_noop_when_screen_already_on(self, mock_run, _mock_cmd):
        mock_run.return_value = MagicMock(
            stdout="mWakefulness=Awake", returncode=0
        )
        ctrl = rpi_presence.AndroidController()
        ctrl.turn_on()
        # Only dumpsys is called, no keyevent
        self.assertEqual(mock_run.call_count, 1)


class TestLoadConfig(unittest.TestCase):
    """Verify config loading falls back to defaults."""

    def test_missing_file_returns_empty_config(self):
        cfg = rpi_presence._load_config("/nonexistent/config.ini")
        self.assertIsInstance(cfg, configparser.ConfigParser)
        self.assertEqual(cfg.sections(), [])


class TestCooldown(unittest.TestCase):
    """Test that the cooldown period suppresses spurious motion re-triggers."""

    def _base_config(self):
        config = configparser.ConfigParser()
        config.read_dict({
            "sensor":  {"gpio_pin": "17", "gpio_method": "sysfs", "gpio_chip": "gpiochip0"},
            "display": {"method": "backlight", "backlight_path": "/fake"},
            "timing":  {"timeout": "60", "poll_interval": "0.5", "cooldown": "10"},
            "logging": {"level": "DEBUG"},
        })
        return config

    def test_motion_during_cooldown_does_not_wake_display(self):
        """Motion immediately after display-off should be ignored during cooldown.

        Sequence of time.monotonic() calls (6 total):
          #1  startup last_motion_time = 0
          #2  iter 1 (no motion): timeout check → 0–0=0 < 60, no action
          #3  iter 2 (no motion): timeout check → 60–0=60 >= 60 → turn_off
          #4  iter 2 (no motion): last_off_time = 60
          #5  iter 3 (motion):    last_motion_time = 61
          #6  iter 3 (motion):    elapsed check → 61–60=1 < 10 → cooldown active
        """
        reader = MagicMock()
        reader.read.side_effect = [False, False, True, StopIteration()]
        display = MagicMock()
        config = self._base_config()

        time_values = iter([0, 0, 60, 60, 61, 61])

        with patch("rpi_presence._load_config", return_value=config), \
             patch("rpi_presence.create_gpio_reader", return_value=reader), \
             patch("rpi_presence.create_display_controller", return_value=display), \
             patch("time.monotonic", side_effect=time_values), \
             patch("time.sleep"):
            with self.assertRaises(StopIteration):
                rpi_presence.run("fake.ini")

        # turn_on called only once (at startup); cooldown blocked the re-trigger
        display.turn_on.assert_called_once()
        display.turn_off.assert_called_once()

    def test_motion_after_cooldown_wakes_display(self):
        """Motion after the cooldown period has elapsed should turn the display on.

        Sequence of time.monotonic() calls (5 total):
          #1  startup last_motion_time = 0
          #2  iter 1 (no motion): timeout check → 60–0=60 >= 60 → turn_off
          #3  iter 1 (no motion): last_off_time = 60
          #4  iter 2 (motion):    last_motion_time = 71
          #5  iter 2 (motion):    elapsed check → 71–60=11 >= 10 → turn_on
        """
        reader = MagicMock()
        reader.read.side_effect = [False, True, StopIteration()]
        display = MagicMock()
        config = self._base_config()

        time_values = iter([0, 60, 60, 71, 71])

        with patch("rpi_presence._load_config", return_value=config), \
             patch("rpi_presence.create_gpio_reader", return_value=reader), \
             patch("rpi_presence.create_display_controller", return_value=display), \
             patch("time.monotonic", side_effect=time_values), \
             patch("time.sleep"):
            with self.assertRaises(StopIteration):
                rpi_presence.run("fake.ini")

        # turn_on called twice: once at startup and once after cooldown
        self.assertEqual(display.turn_on.call_count, 2)
        display.turn_off.assert_called_once()


if __name__ == "__main__":
    unittest.main()
