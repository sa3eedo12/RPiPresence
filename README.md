# RPiPresence

Keep a Raspberry Pi display alive while a motion / presence sensor detects
activity. Designed for a Raspberry Pi running **emteriaOS** with a
touchscreen, but also works on Raspberry Pi OS with DSI displays.

## How it works

A PIR motion sensor (e.g. HC-SR501) is connected to a GPIO pin.
`rpi_presence.py` polls the pin and:

* **Turns the display ON** the moment motion is detected.
* **Turns the display OFF** after a configurable idle timeout with no motion.

### Supported backends

| Backend | GPIO reading | Display control |
|---|---|---|
| **gpiod** (default) | libgpiod ≥ 2 Python bindings | — |
| **sysfs** | Legacy `/sys/class/gpio` | — |
| **RPi.GPIO** | `RPi.GPIO` library | — |
| **backlight** | — | `/sys/class/backlight/rpi_backlight` (official RPi DSI touchscreen) |
| **android** | — | `input keyevent` (emteriaOS / Android) |

Both the GPIO reader and the display controller can be set to **auto**
(the default), which tries each backend in order until one works.

## Wiring

Connect the PIR sensor to the Raspberry Pi:

| PIR Pin | RPi Pin |
|---|---|
| VCC | 5 V (pin 2) |
| OUT | GPIO 17 (pin 11) – configurable |
| GND | Ground (pin 6) |

## Installation

```bash
# Clone the repository
git clone https://github.com/sa3eedo12/RPiPresence.git
cd RPiPresence

# Install Python dependencies
pip install -r requirements.txt

# Copy files to /opt (or any preferred location)
sudo mkdir -p /opt/rpi_presence
sudo cp rpi_presence.py config.ini /opt/rpi_presence/

# Edit the configuration
sudo nano /opt/rpi_presence/config.ini
```

## Configuration

All settings live in `config.ini`:

```ini
[sensor]
gpio_pin = 17          # BCM GPIO pin for the motion sensor
gpio_method = auto     # auto | gpiod | sysfs | rpigpio
gpio_chip = gpiochip0  # gpiod chip device

[display]
method = auto          # auto | backlight | android
backlight_path = /sys/class/backlight/rpi_backlight

[timing]
timeout = 60           # seconds of no motion before display turns off
poll_interval = 0.5    # seconds between sensor reads

[logging]
level = INFO           # DEBUG, INFO, WARNING, ERROR
```

## Usage

### Run directly

```bash
sudo python3 rpi_presence.py              # uses ./config.ini
sudo python3 rpi_presence.py /path/to/config.ini
```

### Run as a systemd service

```bash
sudo cp rpi_presence.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now rpi_presence
```

Check logs:

```bash
journalctl -u rpi_presence -f
```

## License

MIT
