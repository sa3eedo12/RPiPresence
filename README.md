# RPiPresence

Keep a Raspberry Pi display alive while a presence sensor detects someone
nearby.  Designed for a Raspberry Pi running **emteriaOS** with a
touchscreen on your desk — the screen turns on when you sit down and off
when you walk away.

## Supported sensors

| Sensor | Interface | Detects stationary people? |
|---|---|---|
| **LD2410C mmWave radar** (default) | UART serial *or* GPIO (OUT pin) | ✅ Yes |
| HC-SR501 PIR (or similar) | GPIO | ❌ Motion only |

The LD2410C is recommended for desk presence because it uses 24 GHz mmWave
radar to detect both **moving and stationary** targets — it knows you're
still at the desk even if you're just reading.

## How it works

`rpi_presence.py` reads the presence sensor and:

* **Turns the display ON** the moment presence is detected.
* **Turns the display OFF** after a configurable idle timeout with no presence.

### Supported backends

| Backend | Sensor reading | Display control |
|---|---|---|
| **ld2410** (default) | UART serial (pyserial) | — |
| **gpiod** | libgpiod ≥ 2 Python bindings | — |
| **sysfs** | Legacy `/sys/class/gpio` | — |
| **RPi.GPIO** | `RPi.GPIO` library | — |
| **backlight** | — | `/sys/class/backlight/rpi_backlight` (official RPi DSI touchscreen) |
| **android** | — | `input keyevent` (emteriaOS / Android) |

The sensor type and display controller can each be set to **auto**
(the default for display), which tries each backend in order until one works.

## Wiring (LD2410C)

### UART mode (recommended — full-featured)

| LD2410C Pin | RPi Pin |
|---|---|
| VCC | 5 V (pin 2) |
| GND | Ground (pin 6) |
| TX | GPIO 15 / RXD (pin 10) |
| RX | GPIO 14 / TXD (pin 8) |

> **Note:** The LD2410C TX connects to the RPi RX and vice-versa.
> On Raspberry Pi OS you may need to enable the serial port:
> `sudo raspi-config` → Interface Options → Serial Port → disable login shell,
> enable serial hardware.  The default serial device is `/dev/ttyS0` (mini UART)
> or `/dev/ttyAMA0` (PL011).

### GPIO mode (simple — for the shell script on emteriaOS)

| LD2410C Pin | RPi Pin |
|---|---|
| VCC | 5 V (pin 2) |
| GND | Ground (pin 6) |
| OUT | GPIO 17 (pin 11) – configurable |

The OUT pin goes **HIGH** when presence is detected and **LOW** when the
area is clear.  No UART wiring needed — this works with the shell script
on emteriaOS without any dependencies.

### Wiring (PIR sensor — legacy)

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
type = ld2410             # ld2410 (UART) | gpio (PIR / LD2410 OUT pin)

# LD2410 UART settings
serial_port = /dev/ttyS0  # serial device
baud_rate = 256000         # LD2410 default baud rate
max_distance = 0           # cm; 0 = full range (e.g. 100 for desk only)

# GPIO settings (used when type = gpio)
gpio_pin = 17              # BCM GPIO pin
gpio_method = auto         # auto | gpiod | sysfs | rpigpio
gpio_chip = gpiochip0      # gpiod chip device

[display]
method = auto              # auto | backlight | android
backlight_path = /sys/class/backlight/rpi_backlight

[timing]
timeout = 15               # seconds without presence before display off
poll_interval = 0.5        # seconds between sensor reads
cooldown = 0               # seconds to ignore sensor after display off (0 for mmWave)

[logging]
level = INFO               # DEBUG, INFO, WARNING, ERROR
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

### emteriaOS (Shell Script — recommended for emteria)

`rpi_presence.sh` is a zero-dependency script that runs natively on
emteriaOS's Android shell.  It reads the **LD2410C OUT pin** (or a PIR
sensor) via sysfs GPIO and controls the display via Android `input keyevent`
or the sysfs backlight interface.  It requires **no Python, no Termux, and
no package installation** — only root access.

#### Features

| Feature | Description |
|---|---|
| **Full config.ini parsing** | Reads all sections: `[sensor]`, `[display]`, `[timing]`, `[logging]` |
| **Display backends** | Auto-detects sysfs backlight (DSI) or Android keyevent — configurable |
| **Startup self-check** | Validates root, GPIO, and display tools before entering the loop |
| **GPIO auto-recovery** | Re-exports the GPIO pin after 3 consecutive read failures |
| **PID file** | Writes `/data/local/tmp/rpi_presence.pid` — prevents duplicate instances |
| **Log rotation** | Automatically trims the log file when it exceeds 1 MB |
| **Config reload** | Send `SIGHUP` to reload `config.ini` without restarting |
| **Heartbeat** | Logs a status line every 5 minutes to confirm the script is alive |
| **Screen state sync** | Periodically checks actual screen state to catch out-of-band changes |

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
# Using the PID file (written automatically by the script)
kill $(cat /data/local/tmp/rpi_presence.pid)
```

Reload config without restarting:

```sh
kill -HUP $(cat /data/local/tmp/rpi_presence.pid)
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
  "parameters": ["-c", "kill $(cat /data/local/tmp/rpi_presence.pid)"]
}
```

**Step 5 — Reload config remotely** (without restart)

```json
{
  "command": "startExecutable",
  "executable": "/system/bin/sh",
  "parameters": ["-c", "kill -HUP $(cat /data/local/tmp/rpi_presence.pid)"]
}
```

#### Shell script configuration

The shell script reads the **same `config.ini`** as the Python script —
all sections are parsed:

| Key | Section | Default | Notes |
|---|---|---|---|
| `gpio_pin` | `[sensor]` | `17` | BCM GPIO pin number (LD2410C OUT or PIR OUT) |
| `method` | `[display]` | `auto` | `auto`, `backlight`, or `android` |
| `backlight_path` | `[display]` | `/sys/class/backlight/rpi_backlight` | Sysfs path for DSI backlight |
| `timeout` | `[timing]` | `15` | Seconds of no presence before display off |
| `poll_interval` | `[timing]` | `1` | Seconds between sensor reads (minimum 1) |
| `cooldown` | `[timing]` | `0` | Seconds to ignore sensor after display turns off |
| `level` | `[logging]` | `INFO` | `DEBUG`, `INFO`, `WARNING`, or `ERROR` |

> **Note:** The shell script uses the LD2410C's **OUT pin** (GPIO) for
> presence detection.  The LD2410 UART settings (`serial_port`, `baud_rate`,
> `max_distance`) are only used by the Python script.  The OUT pin provides
> the same presence/no-presence detection — the sensor does all the signal
> processing internally.  To limit detection range, configure the LD2410C
> directly using the HLKRadarTool app (available on Google Play).

## Script vs. Android App

For this use case (presence-based screen control on emteriaOS), **a shell
script is the better choice**.  Here's why:

| | Shell script | Android app |
|---|---|---|
| **Dependencies** | None — runs on any emteriaOS shell | Needs Android SDK, build toolchain, APK signing |
| **GPIO access** | Direct via sysfs (root) | Requires JNI or root workarounds |
| **Resource usage** | ~1 MB RSS, negligible CPU | Dalvik/ART VM overhead, ~20–50 MB |
| **Deployment** | `scp` one file, or push via Device Hub | Build APK, sideload or push via MDM |
| **Customisation** | Edit `config.ini` in any text editor | Recompile and reinstall the APK |
| **Reliability** | Survives low-memory kills (tiny footprint) | Android may kill background services |
| **Debugging** | `tail -f` the log over SSH | Logcat, Android Studio |
| **Boot persistence** | `nohup` or init.d | BroadcastReceiver + foreground service |

An Android app would make sense if you needed a **settings UI on the
touchscreen**, integration with Android sensors/APIs, or Play Store
distribution.  For a headless "read a GPIO pin, toggle the screen" daemon,
the shell script is simpler, lighter, and more reliable.

## License

MIT
