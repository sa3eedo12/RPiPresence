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
COOLDOWN=10
LOG_LEVEL=INFO

# Maximum 32-bit signed integer — used to effectively disable Android's screen timeout
ANDROID_TIMEOUT_NEVER=2147483647

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
            cooldown*=*)
                if [ "$_in_timing" = "1" ]; then
                    _val=$(printf '%s' "$_line" | sed 's/^cooldown[[:space:]]*=[[:space:]]*//')
                    # Drop fractional part — shell arithmetic requires integers
                    _val=$(printf '%s' "$_val" | sed 's/\..*//')
                    # Clamp to at least 0
                    if [ -z "$_val" ]; then
                        _val=0
                    elif [ "$_val" -lt 0 ] 2>/dev/null; then
                        _val=0
                    fi
                    COOLDOWN="$_val"
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

log_debug() {
    if [ "$LOG_LEVEL" = "DEBUG" ]; then
        printf '%s [DEBUG] rpi_presence: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    fi
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
    TIMEOUT_MS=$((TIMEOUT * 1000))
    settings put system screen_off_timeout "$TIMEOUT_MS" 2>/dev/null || true
    log "Restored Android screen timeout to ${TIMEOUT_MS}ms"
    log "Shutting down — cleaning up GPIO${GPIO_PIN}"
    gpio_unexport
    log "RPiPresence stopped"
    exit 0
}

trap cleanup INT TERM

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "Starting RPiPresence (pin=${GPIO_PIN}, timeout=${TIMEOUT}s, poll=${POLL_INTERVAL}s, cooldown=${COOLDOWN}s)"
log "Config: ${CONFIG_FILE}"

gpio_export

settings put system screen_off_timeout "$ANDROID_TIMEOUT_NEVER" 2>/dev/null || true
log "Disabled Android screen timeout (set to max)"

# Record startup time as the last-motion timestamp
LAST_MOTION=$(date +%s)
# Track when the display was last turned off (0 = never)
LAST_OFF_TIME=0

# Assume screen starts on; sync with actual state
if screen_is_on; then
    SCREEN_ON=1
else
    SCREEN_ON=0
fi

log "Initial screen state: $([ "$SCREEN_ON" = "1" ] && printf 'ON' || printf 'OFF')"

# Emit a heartbeat log every HEARTBEAT_INTERVAL seconds even when nothing changes
HEARTBEAT_INTERVAL=300
LAST_HEARTBEAT=$(date +%s)

# Verify actual screen state every SCREEN_CHECK_INTERVAL seconds to catch
# display changes made outside this script (e.g. Android screen timeout)
SCREEN_CHECK_INTERVAL=30
LAST_SCREEN_CHECK=$(date +%s)

while true; do
    # Read sensor value (0 or 1)
    if ! VAL=$(cat "${GPIO_PATH}/value" 2>/dev/null); then
        log "WARNING: failed to read ${GPIO_PATH}/value — defaulting to 0"
        VAL=0
    fi
    NOW=$(date +%s)

    if [ "$VAL" = "1" ]; then
        if [ "$SCREEN_ON" = "0" ]; then
            _elapsed=$((NOW - LAST_OFF_TIME))
            if [ "$COOLDOWN" -gt 0 ] && [ "$_elapsed" -lt "$COOLDOWN" ]; then
                _remaining=$((COOLDOWN - _elapsed))
                log_debug "Cooldown active — ignoring motion (${_remaining}s remaining)"
            else
                LAST_MOTION=$NOW
                log "Motion detected — turning display ON"
                screen_on
                SCREEN_ON=1
            fi
        else
            LAST_MOTION=$NOW
        fi
    else
        IDLE=$((NOW - LAST_MOTION))
        if [ "$SCREEN_ON" = "1" ] && [ "$IDLE" -ge "$TIMEOUT" ]; then
            log "No motion for ${IDLE}s — turning display OFF"
            screen_off
            SCREEN_ON=0
            LAST_OFF_TIME=$NOW
        fi
    fi

    # Periodically verify actual screen state to catch out-of-band changes
    # (e.g. Android screen timeout or lock screen turning the display off)
    if [ "$((NOW - LAST_SCREEN_CHECK))" -ge "$SCREEN_CHECK_INTERVAL" ]; then
        LAST_SCREEN_CHECK=$NOW
        if screen_is_on; then
            SCREEN_ON=1
        else
            if [ "$SCREEN_ON" = "1" ]; then
                log "Screen was off unexpectedly — turning display ON"
                screen_on
                SCREEN_ON=1
            fi
        fi
    fi

    # Periodic heartbeat so the log confirms the script is alive
    if [ "$((NOW - LAST_HEARTBEAT))" -ge "$HEARTBEAT_INTERVAL" ]; then
        IDLE=$((NOW - LAST_MOTION))
        if screen_is_on; then _hb_screen=ON; else _hb_screen=OFF; fi
        log "Heartbeat — sensor=${VAL} screen=${_hb_screen} idle=${IDLE}s"
        LAST_HEARTBEAT=$NOW
        LAST_SCREEN_CHECK=$NOW
    fi

    sleep "$POLL_INTERVAL"
done
