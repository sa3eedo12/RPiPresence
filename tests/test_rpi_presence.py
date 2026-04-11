"""Tests for RPiPresence core logic."""

import configparser
import unittest
from unittest.mock import MagicMock, patch, PropertyMock

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


class TestCreateSensorReader(unittest.TestCase):
    """Verify the sensor reader factory dispatches on type."""

    def test_unknown_type_raises(self):
        config = configparser.ConfigParser()
        config.read_dict({"sensor": {"type": "bogus"}})
        with self.assertRaises(ValueError):
            rpi_presence.create_sensor_reader(config)

    @patch("serial.Serial")
    def test_ld2410_type_returns_ld2410_reader(self, mock_serial):
        config = configparser.ConfigParser()
        config.read_dict({
            "sensor": {
                "type": "ld2410",
                "serial_port": "/dev/ttyS0",
                "baud_rate": "256000",
                "max_distance": "100",
            },
        })
        reader = rpi_presence.create_sensor_reader(config)
        self.assertIsInstance(reader, rpi_presence.LD2410Reader)
        mock_serial.assert_called_once_with("/dev/ttyS0", 256000, timeout=0.1)

    def test_gpio_type_falls_through_when_no_backend(self):
        config = configparser.ConfigParser()
        config.read_dict({
            "sensor": {
                "type": "gpio",
                "gpio_pin": "17",
                "gpio_method": "sysfs",
                "gpio_chip": "gpiochip0",
            },
        })
        # sysfs path won't exist in test env
        with self.assertRaises(RuntimeError):
            rpi_presence.create_sensor_reader(config)


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


class TestLD2410Reader(unittest.TestCase):
    """Test the LD2410 mmWave UART reader with mocked serial."""

    _HEADER = bytes([0xF4, 0xF3, 0xF2, 0xF1])
    _FOOTER = bytes([0xF8, 0xF7, 0xF6, 0xF5])

    def _make_reader(self, max_distance=0):
        """Create an LD2410Reader with a mocked serial port."""
        reader = rpi_presence.LD2410Reader.__new__(rpi_presence.LD2410Reader)
        reader._serial = MagicMock()
        reader._max_distance = max_distance
        reader._buffer = bytearray()
        return reader

    def _build_frame(self, target_state, moving_dist=0, moving_energy=0,
                     stationary_dist=0, stationary_energy=0, detection_dist=0):
        """Build a complete LD2410 target-data frame."""
        data = bytearray()
        data.extend([0x02, 0xAA])                             # data type
        data.append(target_state)                              # target state
        data.extend(moving_dist.to_bytes(2, "little"))         # moving distance
        data.append(moving_energy)                             # moving energy
        data.extend(stationary_dist.to_bytes(2, "little"))     # stationary distance
        data.append(stationary_energy)                         # stationary energy
        data.extend(detection_dist.to_bytes(2, "little"))      # detection distance

        frame = bytearray()
        frame.extend(self._HEADER)
        frame.extend(len(data).to_bytes(2, "little"))
        frame.extend(data)
        frame.extend(self._FOOTER)
        return bytes(frame)

    def test_no_target_returns_false(self):
        reader = self._make_reader()
        frame = self._build_frame(target_state=0x00)
        reader._serial.in_waiting = len(frame)
        reader._serial.read.return_value = frame
        self.assertFalse(reader.read())

    def test_moving_target_returns_true(self):
        reader = self._make_reader()
        frame = self._build_frame(target_state=0x01, moving_dist=80,
                                  moving_energy=50, detection_dist=80)
        reader._serial.in_waiting = len(frame)
        reader._serial.read.return_value = frame
        self.assertTrue(reader.read())

    def test_stationary_target_returns_true(self):
        reader = self._make_reader()
        frame = self._build_frame(target_state=0x02, stationary_dist=60,
                                  stationary_energy=70, detection_dist=60)
        reader._serial.in_waiting = len(frame)
        reader._serial.read.return_value = frame
        self.assertTrue(reader.read())

    def test_both_targets_returns_true(self):
        reader = self._make_reader()
        frame = self._build_frame(target_state=0x03, moving_dist=100,
                                  stationary_dist=60, detection_dist=60)
        reader._serial.in_waiting = len(frame)
        reader._serial.read.return_value = frame
        self.assertTrue(reader.read())

    def test_max_distance_filters_far_target(self):
        reader = self._make_reader(max_distance=100)
        frame = self._build_frame(target_state=0x02, stationary_dist=150,
                                  stationary_energy=40, detection_dist=150)
        reader._serial.in_waiting = len(frame)
        reader._serial.read.return_value = frame
        self.assertFalse(reader.read())

    def test_max_distance_allows_close_target(self):
        reader = self._make_reader(max_distance=100)
        frame = self._build_frame(target_state=0x02, stationary_dist=80,
                                  stationary_energy=50, detection_dist=80)
        reader._serial.in_waiting = len(frame)
        reader._serial.read.return_value = frame
        self.assertTrue(reader.read())

    def test_empty_buffer_returns_false(self):
        reader = self._make_reader()
        reader._serial.in_waiting = 0
        reader._serial.read.return_value = b""
        self.assertFalse(reader.read())

    def test_partial_frame_returns_false(self):
        reader = self._make_reader()
        partial = self._HEADER + b"\x0b\x00\x02\xAA"  # header + length + partial data
        reader._serial.in_waiting = len(partial)
        reader._serial.read.return_value = partial
        self.assertFalse(reader.read())
        # Buffer should retain partial data for next read
        self.assertTrue(len(reader._buffer) > 0)

    def test_bad_footer_skips_frame(self):
        """A frame with a corrupt footer should be skipped."""
        reader = self._make_reader()
        # Build a valid frame but corrupt the footer
        data = bytes([0x02, 0xAA, 0x02, 0, 0, 50, 0, 60, 50, 60, 0])
        bad_frame = self._HEADER + len(data).to_bytes(2, "little") + data + b"\x00\x00\x00\x00"
        reader._serial.in_waiting = len(bad_frame)
        reader._serial.read.return_value = bad_frame
        self.assertFalse(reader.read())

    def test_multiple_frames_uses_latest(self):
        """When multiple frames are buffered, the last one wins."""
        reader = self._make_reader()
        frame_no_target = self._build_frame(target_state=0x00)
        frame_present = self._build_frame(target_state=0x02, detection_dist=50)
        combined = frame_no_target + frame_present
        reader._serial.in_waiting = len(combined)
        reader._serial.read.return_value = combined
        self.assertTrue(reader.read())

    def test_cleanup_closes_serial(self):
        reader = self._make_reader()
        reader.cleanup()
        reader._serial.close.assert_called_once()

    def test_buffer_trimmed_when_oversized(self):
        reader = self._make_reader()
        reader._serial.in_waiting = 600
        reader._serial.read.return_value = b"\x00" * 600
        reader.read()
        self.assertLessEqual(len(reader._buffer), rpi_presence.LD2410Reader._MAX_BUFFER)


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
    """Test that the cooldown period suppresses spurious re-triggers."""

    def _base_config(self):
        config = configparser.ConfigParser()
        config.read_dict({
            "sensor":  {"type": "gpio", "gpio_pin": "17", "gpio_method": "sysfs", "gpio_chip": "gpiochip0"},
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
             patch("rpi_presence.create_sensor_reader", return_value=reader), \
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
             patch("rpi_presence.create_sensor_reader", return_value=reader), \
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
