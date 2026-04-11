#!/system/bin/sh
# rpi_presence.sh — Zero-dependency presence script for emteriaOS (Android).
#
# Polls an LD2410C mmWave presence sensor (or PIR) via sysfs GPIO and
# controls the display.  Requires no Python, Termux, or any package
# installation — only root access and the commands available in a standard
# emteriaOS shell.
#
# The LD2410C OUT pin goes HIGH when presence is detected and LOW when no
# target is in range.  This works exactly like a PIR sensor from the GPIO
# perspective, but detects stationary people as well.
#
# Features:
#   • Full config.ini parsing ([sensor], [display], [timing], [logging])
#   • Display control via sysfs backlight (DSI) or Android keyevent
#   • Startup self-check (root, GPIO, display tools)
#   • GPIO auto-recovery on read failure
#   • PID file for process management
#   • Log rotation to prevent unbounded growth
#   • Graceful shutdown with SIGINT/SIGTERM; config reload with SIGHUP
#
# Usage:
#   sh rpi_presence.sh [config.ini]

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

CONFIG_FILE="${1:-config.ini}"

GPIO_PIN=17
TIMEOUT=15
POLL_INTERVAL=1
COOLDOWN=0
LOG_LEVEL=INFO
DISPLAY_METHOD=auto
BACKLIGHT_PATH=/sys/class/backlight/rpi_backlight

# PID file location
PID_FILE=/data/local/tmp/rpi_presence.pid

# Maximum 32-bit signed integer — effectively disables Android's screen timeout
ANDROID_TIMEOUT_NEVER=2147483647

# Maximum log file size in bytes before rotation (1 MB)
MAX_LOG_SIZE=1048576

# Sysfs bl_power values (kernel interface: 0 = on, 1 = off)
BL_POWER_ON=0
BL_POWER_OFF=1

# Emit a heartbeat log every HEARTBEAT_INTERVAL seconds
HEARTBEAT_INTERVAL=300

# Verify actual screen state every SCREEN_CHECK_INTERVAL seconds
SCREEN_CHECK_INTERVAL=30

# Number of consecutive GPIO failures before attempting recovery
GPIO_FAIL_THRESHOLD=3

# ---------------------------------------------------------------------------
# Config parser
# ---------------------------------------------------------------------------

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return
    fi

    _section=""
    while IFS= read -r _line || [ -n "$_line" ]; do
        # Strip inline comments and surrounding whitespace
        _line=$(printf '%s' "$_line" | sed 's/[;#].*$//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [ -z "$_line" ] && continue

        case "$_line" in
            \[*\])
                _section=$(printf '%s' "$_line" | sed 's/^\[//;s/\]$//')
                ;;
            *=*)
                _key=$(printf '%s' "$_line" | sed 's/[[:space:]]*=.*//')
                _val=$(printf '%s' "$_line" | sed 's/^[^=]*=[[:space:]]*//')
                [ -z "$_val" ] && continue

                case "${_section}/${_key}" in
                    sensor/gpio_pin)
                        GPIO_PIN="$_val" ;;
                    display/method)
                        DISPLAY_METHOD="$_val" ;;
                    display/backlight_path)
                        BACKLIGHT_PATH="$_val" ;;
                    timing/timeout)
                        # Drop fractional part — shell arithmetic requires integers
                        _val=$(printf '%s' "$_val" | sed 's/\..*//')
                        [ -n "$_val" ] && TIMEOUT="$_val"
                        ;;
                    timing/poll_interval)
                        _val=$(printf '%s' "$_val" | sed 's/\..*//')
                        # Clamp to at least 1 second (Android sleep requires integers)
                        if [ -z "$_val" ]; then _val=1
                        elif [ "$_val" -lt 1 ] 2>/dev/null; then _val=1; fi
                        POLL_INTERVAL="$_val"
                        ;;
                    timing/cooldown)
                        _val=$(printf '%s' "$_val" | sed 's/\..*//')
                        if [ -z "$_val" ]; then _val=0
                        elif [ "$_val" -lt 0 ] 2>/dev/null; then _val=0; fi
                        COOLDOWN="$_val"
                        ;;
                    logging/level)
                        # Normalize to uppercase
                        _val=$(printf '%s' "$_val" | tr '[:lower:]' '[:upper:]')
                        case "$_val" in
                            DEBUG|INFO|WARNING|ERROR) LOG_LEVEL="$_val" ;;
                        esac
                        ;;
                esac
                ;;
        esac
    done < "$CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_log() {
    printf '%s [%s] rpi_presence: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"
}

log_error() { _log "ERROR" "$*"; }

log_warn() {
    case "$LOG_LEVEL" in ERROR) return ;; esac
    _log "WARNING" "$*"
}

log() {
    case "$LOG_LEVEL" in ERROR|WARNING) return ;; esac
    _log "INFO" "$*"
}

log_debug() {
    case "$LOG_LEVEL" in DEBUG) ;; *) return ;; esac
    _log "DEBUG" "$*"
}

# Rotate the log file if it exceeds MAX_LOG_SIZE.
# Only relevant when stdout is redirected to a file (nohup usage).
rotate_log() {
    _log_file=""
    # Detect if stdout is a regular file (i.e. redirected to a log)
    if [ -f "/proc/$$/fd/1" ] 2>/dev/null; then
        _log_file=$(readlink "/proc/$$/fd/1" 2>/dev/null)
    elif [ -L "/proc/self/fd/1" ]; then
        _log_file=$(readlink "/proc/self/fd/1" 2>/dev/null)
    fi
    [ -z "$_log_file" ] && return
    [ ! -f "$_log_file" ] && return

    _size=$(wc -c < "$_log_file" 2>/dev/null)
    [ -z "$_size" ] && return

    if [ "$_size" -gt "$MAX_LOG_SIZE" ] 2>/dev/null; then
        # Keep the last half of the file
        _lines=$(wc -l < "$_log_file" 2>/dev/null)
        _keep=$((_lines / 2))
        if [ "$_keep" -gt 0 ]; then
            tail -n "$_keep" "$_log_file" > "${_log_file}.tmp" 2>/dev/null
            mv "${_log_file}.tmp" "$_log_file" 2>/dev/null
            log "Log rotated — kept last ${_keep} lines"
        fi
    fi
}

# ---------------------------------------------------------------------------
# GPIO
# ---------------------------------------------------------------------------

GPIO_PATH=""
GPIO_FAIL_COUNT=0

gpio_setup() {
    GPIO_PATH="/sys/class/gpio/gpio${GPIO_PIN}"
    if [ ! -d "$GPIO_PATH" ]; then
        printf '%s' "$GPIO_PIN" > /sys/class/gpio/export 2>/dev/null || true
        sleep 1
    fi
    printf 'in' > "${GPIO_PATH}/direction" 2>/dev/null || true
    GPIO_FAIL_COUNT=0
    log "GPIO${GPIO_PIN} exported and set to input"
}

gpio_cleanup() {
    printf '%s' "$GPIO_PIN" > /sys/class/gpio/unexport 2>/dev/null || true
    log_debug "GPIO${GPIO_PIN} unexported"
}

gpio_read() {
    if _val=$(cat "${GPIO_PATH}/value" 2>/dev/null); then
        GPIO_FAIL_COUNT=0
        GPIO_VAL="$_val"
        return 0
    fi

    GPIO_FAIL_COUNT=$((GPIO_FAIL_COUNT + 1))
    log_warn "Failed to read ${GPIO_PATH}/value (failure ${GPIO_FAIL_COUNT}/${GPIO_FAIL_THRESHOLD})"

    if [ "$GPIO_FAIL_COUNT" -ge "$GPIO_FAIL_THRESHOLD" ]; then
        log_warn "GPIO read failed ${GPIO_FAIL_THRESHOLD} times — re-exporting pin"
        gpio_cleanup
        sleep 1
        gpio_setup
    fi

    GPIO_VAL=0
    return 1
}

# ---------------------------------------------------------------------------
# Display controller
# ---------------------------------------------------------------------------

# Resolved at startup; one of: backlight, android
DISPLAY_BACKEND=""

display_detect() {
    # When method is "auto", try backlight first, then fall back to android.
    case "$DISPLAY_METHOD" in
        backlight)
            if [ -f "${BACKLIGHT_PATH}/bl_power" ]; then
                DISPLAY_BACKEND=backlight
            else
                log_error "Backlight path not found: ${BACKLIGHT_PATH}/bl_power"
                return 1
            fi
            ;;
        android)
            if command -v input >/dev/null 2>&1; then
                DISPLAY_BACKEND=android
            else
                log_error "'input' command not found — not an Android system?"
                return 1
            fi
            ;;
        auto|*)
            if [ -f "${BACKLIGHT_PATH}/bl_power" ]; then
                DISPLAY_BACKEND=backlight
            elif command -v input >/dev/null 2>&1; then
                DISPLAY_BACKEND=android
            else
                log_error "No display backend available (tried backlight + android)"
                return 1
            fi
            ;;
    esac
    log "Display backend: ${DISPLAY_BACKEND}"
    return 0
}

screen_is_on() {
    case "$DISPLAY_BACKEND" in
        backlight)
            # bl_power: 0 = on, 1 = off
            [ "$(cat "${BACKLIGHT_PATH}/bl_power" 2>/dev/null)" = "$BL_POWER_ON" ]
            ;;
        android)
            dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake'
            ;;
    esac
}

screen_on() {
    case "$DISPLAY_BACKEND" in
        backlight)
            printf '%s' "$BL_POWER_ON" > "${BACKLIGHT_PATH}/bl_power" 2>/dev/null || true
            ;;
        android)
            if ! screen_is_on; then
                input keyevent KEYCODE_WAKEUP 2>/dev/null || true
            fi
            ;;
    esac
    log_debug "Display turned ON"
}

screen_off() {
    case "$DISPLAY_BACKEND" in
        backlight)
            printf '%s' "$BL_POWER_OFF" > "${BACKLIGHT_PATH}/bl_power" 2>/dev/null || true
            ;;
        android)
            if screen_is_on; then
                input keyevent KEYCODE_SLEEP 2>/dev/null || true
            fi
            ;;
    esac
    log_debug "Display turned OFF"
}

# ---------------------------------------------------------------------------
# PID file
# ---------------------------------------------------------------------------

write_pid() {
    printf '%s' "$$" > "$PID_FILE" 2>/dev/null || true
    log_debug "PID file: ${PID_FILE} ($$)"
}

remove_pid() {
    rm -f "$PID_FILE" 2>/dev/null || true
}

check_already_running() {
    if [ -f "$PID_FILE" ]; then
        _old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$_old_pid" ] && [ -d "/proc/$_old_pid" ]; then
            log_error "Another instance is already running (PID ${_old_pid})"
            log_error "Stop it first: kill $_old_pid"
            exit 1
        fi
        # Stale PID file — previous instance crashed
        log_warn "Removing stale PID file (old PID: ${_old_pid})"
        remove_pid
    fi
}

# ---------------------------------------------------------------------------
# Startup self-check
# ---------------------------------------------------------------------------

self_check() {
    _ok=1

    # Root check
    if [ "$(id -u)" != "0" ]; then
        log_warn "Not running as root — GPIO and display control may fail"
    fi

    # GPIO check
    if [ ! -d "/sys/class/gpio" ]; then
        log_error "Self-check FAILED: /sys/class/gpio not found — GPIO not available"
        _ok=0
    fi

    # Display backend check (already done in display_detect)
    if [ -z "$DISPLAY_BACKEND" ]; then
        log_error "Self-check FAILED: no display backend detected"
        _ok=0
    fi

    if [ "$_ok" = "0" ]; then
        log_error "Self-check failed — aborting"
        exit 1
    fi

    log "Self-check passed"
}

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------

cleanup() {
    # Restore Android screen timeout if we changed it
    if [ "$DISPLAY_BACKEND" = "android" ]; then
        TIMEOUT_MS=$((TIMEOUT * 1000))
        settings put system screen_off_timeout "$TIMEOUT_MS" 2>/dev/null || true
        log "Restored Android screen timeout to ${TIMEOUT_MS}ms"
    fi

    gpio_cleanup
    remove_pid
    log "RPiPresence stopped"
    exit 0
}

# ---------------------------------------------------------------------------
# SIGHUP handler — reload configuration
# ---------------------------------------------------------------------------

RELOAD_REQUESTED=0

request_reload() {
    RELOAD_REQUESTED=1
}

do_reload() {
    RELOAD_REQUESTED=0
    _old_pin="$GPIO_PIN"
    _old_timeout="$TIMEOUT"
    _old_poll="$POLL_INTERVAL"
    _old_cooldown="$COOLDOWN"
    _old_log_level="$LOG_LEVEL"

    load_config

    log "Config reloaded from ${CONFIG_FILE}"

    # If GPIO pin changed, re-export
    if [ "$GPIO_PIN" != "$_old_pin" ]; then
        log "GPIO pin changed: ${_old_pin} -> ${GPIO_PIN} — re-exporting"
        gpio_cleanup
        gpio_setup
    fi

    # Log what changed
    [ "$TIMEOUT" != "$_old_timeout" ] && log "timeout: ${_old_timeout}s -> ${TIMEOUT}s"
    [ "$POLL_INTERVAL" != "$_old_poll" ] && log "poll_interval: ${_old_poll}s -> ${POLL_INTERVAL}s"
    [ "$COOLDOWN" != "$_old_cooldown" ] && log "cooldown: ${_old_cooldown}s -> ${COOLDOWN}s"
    [ "$LOG_LEVEL" != "$_old_log_level" ] && log "log_level: ${_old_log_level} -> ${LOG_LEVEL}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

load_config

check_already_running

# Detect display backend before self-check
display_detect || exit 1
self_check

write_pid

trap cleanup INT TERM
trap request_reload HUP

log "Starting RPiPresence (pin=${GPIO_PIN}, timeout=${TIMEOUT}s, poll=${POLL_INTERVAL}s, cooldown=${COOLDOWN}s)"
log "Config: ${CONFIG_FILE}"
log "Log level: ${LOG_LEVEL}"

gpio_setup

# Disable Android screen timeout so the script has full control
if [ "$DISPLAY_BACKEND" = "android" ]; then
    _saved_timeout=$(settings get system screen_off_timeout 2>/dev/null)
    settings put system screen_off_timeout "$ANDROID_TIMEOUT_NEVER" 2>/dev/null || true
    log "Disabled Android screen timeout (was ${_saved_timeout}ms, set to max)"
fi

# Record startup time as the last-presence timestamp
LAST_PRESENCE=$(date +%s)
LAST_OFF_TIME=0
LAST_HEARTBEAT=$(date +%s)
LAST_SCREEN_CHECK=$(date +%s)
LAST_LOG_CHECK=$(date +%s)

# Sync with actual screen state
if screen_is_on; then
    SCREEN_ON=1
else
    SCREEN_ON=0
fi

log "Initial screen state: $([ "$SCREEN_ON" = "1" ] && printf 'ON' || printf 'OFF')"

while true; do
    # Handle pending config reload
    if [ "$RELOAD_REQUESTED" = "1" ]; then
        do_reload
    fi

    # Read sensor
    gpio_read
    NOW=$(date +%s)

    if [ "$GPIO_VAL" = "1" ]; then
        if [ "$SCREEN_ON" = "0" ]; then
            _elapsed=$((NOW - LAST_OFF_TIME))
            if [ "$COOLDOWN" -gt 0 ] && [ "$_elapsed" -lt "$COOLDOWN" ]; then
                _remaining=$((COOLDOWN - _elapsed))
                log_debug "Cooldown active — ignoring presence (${_remaining}s remaining)"
            else
                LAST_PRESENCE=$NOW
                log "Presence detected — turning display ON"
                screen_on
                SCREEN_ON=1
            fi
        else
            LAST_PRESENCE=$NOW
        fi
    else
        IDLE=$((NOW - LAST_PRESENCE))
        if [ "$SCREEN_ON" = "1" ] && [ "$IDLE" -ge "$TIMEOUT" ]; then
            log "No presence for ${IDLE}s — turning display OFF"
            screen_off
            SCREEN_ON=0
            LAST_OFF_TIME=$NOW
        fi
    fi

    # Periodically verify actual screen state to catch out-of-band changes
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

    # Periodic heartbeat
    if [ "$((NOW - LAST_HEARTBEAT))" -ge "$HEARTBEAT_INTERVAL" ]; then
        IDLE=$((NOW - LAST_PRESENCE))
        if screen_is_on; then _hb_screen=ON; else _hb_screen=OFF; fi
        log "Heartbeat — sensor=${GPIO_VAL} screen=${_hb_screen} idle=${IDLE}s gpio_ok=$((GPIO_FAIL_THRESHOLD - GPIO_FAIL_COUNT))/${GPIO_FAIL_THRESHOLD}"
        LAST_HEARTBEAT=$NOW
        LAST_SCREEN_CHECK=$NOW
    fi

    # Periodic log rotation check (every 60s)
    if [ "$((NOW - LAST_LOG_CHECK))" -ge 60 ]; then
        LAST_LOG_CHECK=$NOW
        rotate_log
    fi

    sleep "$POLL_INTERVAL"
done
