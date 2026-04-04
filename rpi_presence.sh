#!/system/bin/sh
# rpi_presence.sh — Zero-dependency presence script for emteriaOS (Android).
#
# Polls a PIR motion sensor via sysfs GPIO and controls the display using
# Android's `input keyevent` command.  Requires no Python, Termux, or any
# package installation — only root access and the commands available in a
# standard emteriaOS shell.
#
# Usage:
#   sh rpi_presence.sh [config.ini]
#
# Defaults (used when config.ini is absent or a value is not set):
#   gpio_pin      = 17
#   timeout       = 60   (seconds)
#   poll_interval = 1    (seconds; Android sleep does not support fractions)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CONFIG_FILE="${1:-config.ini}"

# Defaults
GPIO_PIN=17
TIMEOUT=60
POLL_INTERVAL=1

# Parse config.ini if it exists (reads [sensor], [timing] sections only)
if [ -f "$CONFIG_FILE" ]; then
    _in_sensor=0
    _in_timing=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        # Strip inline comments and surrounding whitespace
        _line=$(printf '%s' "$_line" | sed 's/[;#].*$//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        case "$_line" in
            \[sensor\])  _in_sensor=1; _in_timing=0 ;;
            \[timing\])  _in_timing=1; _in_sensor=0 ;;
            \[*\])       _in_sensor=0; _in_timing=0 ;;
            gpio_pin*=*)
                if [ "$_in_sensor" = "1" ]; then
                    _val=$(printf '%s' "$_line" | sed 's/^gpio_pin[[:space:]]*=[[:space:]]*//')
                    [ -n "$_val" ] && GPIO_PIN="$_val"
                fi
                ;;
            timeout*=*)
                if [ "$_in_timing" = "1" ]; then
                    _val=$(printf '%s' "$_line" | sed 's/^timeout[[:space:]]*=[[:space:]]*//')
                    # Drop fractional part — Android sleep requires integers
                    _val=$(printf '%s' "$_val" | sed 's/\..*//')
                    [ -n "$_val" ] && TIMEOUT="$_val"
                fi
                ;;
            poll_interval*=*)
                if [ "$_in_timing" = "1" ]; then
                    _val=$(printf '%s' "$_line" | sed 's/^poll_interval[[:space:]]*=[[:space:]]*//')
                    # Drop fractional part — Android sleep requires integers
                    _val=$(printf '%s' "$_val" | sed 's/\..*//')
                    # Clamp to at least 1 second
                    if [ -z "$_val" ]; then
                        _val=1
                    elif [ "$_val" -lt 1 ] 2>/dev/null; then
                        _val=1
                    fi
                    POLL_INTERVAL="$_val"
                fi
                ;;
        esac
    done < "$CONFIG_FILE"
fi

GPIO_PATH="/sys/class/gpio/gpio${GPIO_PIN}"

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------

log() {
    printf '%s [INFO] rpi_presence: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# ---------------------------------------------------------------------------
# GPIO setup
# ---------------------------------------------------------------------------

gpio_export() {
    if [ ! -d "$GPIO_PATH" ]; then
        printf '%s' "$GPIO_PIN" > /sys/class/gpio/export 2>/dev/null || true
        # Wait briefly for the kernel to create the sysfs entry
        sleep 1
    fi
    printf 'in' > "${GPIO_PATH}/direction" 2>/dev/null || true
    log "GPIO${GPIO_PIN} exported and set to input"
}

gpio_unexport() {
    printf '%s' "$GPIO_PIN" > /sys/class/gpio/unexport 2>/dev/null || true
    log "GPIO${GPIO_PIN} unexported"
}

# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

screen_is_on() {
    dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake'
}

screen_on() {
    input keyevent KEYCODE_WAKEUP 2>/dev/null || true
    log "Display turned ON"
}

screen_off() {
    input keyevent KEYCODE_SLEEP 2>/dev/null || true
    log "Display turned OFF"
}

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------

cleanup() {
    log "Shutting down — cleaning up GPIO${GPIO_PIN}"
    gpio_unexport
    log "RPiPresence stopped"
    exit 0
}

trap cleanup INT TERM

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "Starting RPiPresence (pin=${GPIO_PIN}, timeout=${TIMEOUT}s, poll=${POLL_INTERVAL}s)"
log "Config: ${CONFIG_FILE}"

gpio_export

# Record startup time as the last-motion timestamp
LAST_MOTION=$(date +%s)

# Assume screen starts on; sync with actual state
if screen_is_on; then
    SCREEN_ON=1
else
    SCREEN_ON=0
fi

log "Initial screen state: $([ "$SCREEN_ON" = "1" ] && printf 'ON' || printf 'OFF')"

while true; do
    # Read sensor value (0 or 1)
    if ! VAL=$(cat "${GPIO_PATH}/value" 2>/dev/null); then
        log "WARNING: failed to read ${GPIO_PATH}/value — defaulting to 0"
        VAL=0
    fi
    NOW=$(date +%s)

    if [ "$VAL" = "1" ]; then
        LAST_MOTION=$NOW
        if [ "$SCREEN_ON" = "0" ]; then
            log "Motion detected — turning display ON"
            screen_on
            SCREEN_ON=1
        fi
    else
        IDLE=$((NOW - LAST_MOTION))
        if [ "$SCREEN_ON" = "1" ] && [ "$IDLE" -ge "$TIMEOUT" ]; then
            log "No motion for ${IDLE}s — turning display OFF"
            screen_off
            SCREEN_ON=0
        fi
    fi

    sleep "$POLL_INTERVAL"
done
