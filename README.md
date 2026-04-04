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

### Raspberry Pi OS (Python)

#### Run directly

```bash
sudo python3 rpi_presence.py              # uses ./config.ini
sudo python3 rpi_presence.py /path/to/config.ini
```

#### Run as a systemd service

```bash
sudo cp rpi_presence.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now rpi_presence
```

Check logs:

```bash
journalctl -u rpi_presence -f
```

### emteriaOS (Shell Script)

`rpi_presence.sh` is a zero-dependency alternative that runs natively on
emteriaOS's Android shell.  It requires **no Python, no Termux, and no
package installation** — only root access and the `input`/`dumpsys` commands
that are already present on emteriaOS.

#### Prerequisites

Verify that your device has the required components over SSH or ADB shell:

```sh
id                       # should show uid=0(root)
ls /sys/class/gpio/      # should list gpiochip0 (and gpio17 after export)
which input              # /system/bin/input
which dumpsys            # /system/bin/dumpsys
```

#### Run directly via SSH

```sh
# Copy the script to the device (run on your workstation)
scp rpi_presence.sh config.ini root@<device-ip>:/data/local/tmp/

# SSH in and run it
ssh root@<device-ip>
cd /data/local/tmp
sh rpi_presence.sh            # uses ./config.ini
sh rpi_presence.sh /path/to/config.ini
```

#### Run via ADB shell

```sh
adb push rpi_presence.sh config.ini /data/local/tmp/
adb shell
cd /data/local/tmp
sh rpi_presence.sh
```

#### Run in the background (persist after SSH logout)

```sh
nohup sh rpi_presence.sh > /data/local/tmp/rpi_presence.log 2>&1 &
echo "PID: $!"
```

Stop it later with:

```sh
kill <PID>
```

#### Configuration

The shell script reads the same `config.ini` file as the Python script.
Only three values are used; all others are ignored:

| Key | Section | Default | Notes |
|---|---|---|---|
| `gpio_pin` | `[sensor]` | `17` | BCM GPIO pin number |
| `timeout` | `[timing]` | `60` | Seconds of no motion before display off |
| `poll_interval` | `[timing]` | `1` | Seconds between sensor reads (fractions are truncated; minimum 1) |

## License

MIT
