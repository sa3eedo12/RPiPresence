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


if __name__ == "__main__":
    unittest.main()
