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
cooldown = 10          # seconds to ignore sensor after display turns off

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

#### Enable SSH on emteriaOS

Before connecting via SSH, enable the built-in SSH server on the device:

1. Open **Settings** on the device.
2. Go to **Emteria Settings → SSH server**.
3. Toggle **Enable SSH server** on.
4. Note the device IP address shown (or find it in Settings → About device → IP address).

You can then connect from your workstation:

```sh
ssh root@<device-ip>
```

For key-based (passwordless) authentication, copy your public key to the device:

```sh
# On your workstation — uploads your public key over SSH
ssh root@<device-ip> "mkdir -p /data/local/.ssh && cat >> /data/local/.ssh/authorized_keys" < ~/.ssh/id_rsa.pub
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

#### Deploy and run via emteria MDM (Device Hub)

[emteria Device Hub](https://emteria.com/device-hub) lets you deploy and
start the script remotely without a direct SSH session — useful for managing
multiple devices or for headless/unattended setups.

**Step 1 — Enable MDM on the device**

1. Open **Settings → Emteria Settings → Device management settings**.
2. Toggle **Enable MDM service** on.
3. The device will appear in your Device Hub dashboard at
   [hub.emteria.com](https://hub.emteria.com).

**Step 2 — Deploy the script via Device Hub**

1. Log in to [hub.emteria.com](https://hub.emteria.com).
2. Select your device (or device group) from the **Devices** list.
3. Open the **Commands** tab and choose **Editor**.
4. Paste the following JSON to write `rpi_presence.sh` and `config.ini` to the
   device and start it in the background:

```json
{
  "command": "processSubcommands",
  "success": "all",
  "subcommands": [
    {
      "command": "downloadFile",
      "url": "https://raw.githubusercontent.com/sa3eedo12/RPiPresence/main/rpi_presence.sh",
      "file": "/data/local/tmp/rpi_presence.sh",
      "mode": "755"
    },
    {
      "command": "downloadFile",
      "url": "https://raw.githubusercontent.com/sa3eedo12/RPiPresence/main/config.ini",
      "file": "/data/local/tmp/config.ini",
      "mode": "644"
    },
    {
      "command": "startExecutable",
      "executable": "/system/bin/sh",
      "parameters": ["-c", "nohup sh /data/local/tmp/rpi_presence.sh /data/local/tmp/config.ini > /data/local/tmp/rpi_presence.log 2>&1 &"]
    }
  ]
}
```

> **Tip:** If you host your own customised `config.ini` (e.g. on a private
> server or via a GitHub raw URL from a fork), replace the `downloadFile` URLs
> with your own.

**Step 3 — Check the script is running**

Send the following command from Device Hub to verify the process is alive and
tail the log:

```json
{
  "command": "processSubcommands",
  "success": "all",
  "subcommands": [
    {
      "command": "startExecutable",
      "executable": "/system/bin/sh",
      "parameters": ["-c", "ps | grep rpi_presence"]
    }
  ]
}
```

Or connect over SSH and inspect the log directly:

```sh
ssh root@<device-ip>
tail -f /data/local/tmp/rpi_presence.log
```

**Step 4 — Stop the script**

```json
{
  "command": "startExecutable",
  "executable": "/system/bin/sh",
  "parameters": ["-c", "kill $(ps | grep rpi_presence.sh | grep -v grep | awk '{print $1}')"]
}
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
