#!/bin/bash
# openclaw-canary.sh — Independent read-only gateway health watcher
#
# Purpose: completely separate from the watchdog. If the watchdog itself breaks
# (as v2 did for 22 hours), the canary still produces a visible signal.
#
# Safety contract (NEVER VIOLATE):
#   - This script NEVER kills processes.
#   - This script NEVER issues SIGTERM, SIGKILL, or any signal.
#   - This script NEVER touches launchctl.
#   - The ONLY mutations it performs are:
#       1. append a line to its own log file
#       2. overwrite its state file (/tmp/openclaw-canary.state)
#       3. append an ALERT entry to ~/.openclaw/ALERT.md (only when degraded)
#   - If gateway is down, this script SITS AND WATCHES. It does not "fix".
#
# Detection thresholds:
#   - WARN after 3 consecutive DOWN observations (~3 minutes of real downtime)
#   - ALERT after 10 consecutive DOWN observations (~10 minutes of real downtime)
#   - ALERT is idempotent: only writes on transitions from "up" to "alert"
#     and on a 30-minute repeat cadence while still down.
#
# Stakes: see memory/project_gateway_stakes.md. This canary exists so that
# if the watchdog ever fails silently again, the user knows within 10 minutes
# instead of 21 hours.

export PATH="$PATH:/usr/sbin:/sbin"
set -u

LOG_FILE="$HOME/.openclaw/logs/canary.log"
STATE_FILE="/tmp/openclaw-canary.state"
ALERT_FILE="$HOME/.openclaw/ALERT.md"
LOCK_FILE="/tmp/openclaw-canary.lock"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

WARN_THRESHOLD=3        # consecutive down observations before WARN logging
ALERT_THRESHOLD=10      # consecutive down observations before ALERT.md entry
ALERT_REPEAT_SECS=1800  # 30 minutes between repeat alerts while still down

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# Log rotation (5MB — higher frequency than watchdog)
if [ -f "$LOG_FILE" ]; then
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    [ "$size" -gt 5242880 ] && mv "$LOG_FILE" "${LOG_FILE}.prev"
fi

# Single-instance guard
if [ -f "$LOCK_FILE" ]; then
    existing_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        log "another canary instance running (pid=$existing_pid) — skip"
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

# ── Check (READ-ONLY) ─────────────────────────────────────
check_port() {
    /usr/sbin/lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN >/dev/null 2>&1
}

# ── State management ──────────────────────────────────────
# State file format:
#   consecutive_down=<int>
#   last_alert_ts=<unix seconds or 0>
#   last_state=<up|down>

load_state() {
    consecutive_down=0
    last_alert_ts=0
    last_state="up"
    [ ! -f "$STATE_FILE" ] && return
    while IFS='=' read -r key value; do
        case "$key" in
            consecutive_down) consecutive_down="$value" ;;
            last_alert_ts)    last_alert_ts="$value" ;;
            last_state)       last_state="$value" ;;
        esac
    done < "$STATE_FILE"
}

save_state() {
    cat > "$STATE_FILE" <<EOF
consecutive_down=$consecutive_down
last_alert_ts=$last_alert_ts
last_state=$last_state
EOF
}

write_alert_entry() {
    local reason="$1"
    {
        echo ""
        echo "## ALERT: Gateway down (canary detection) — $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "- **Reason:** $reason"
        echo "- **Gateway port 18789 listening:** no"
        echo "- **Consecutive down observations:** $consecutive_down (each ~1 min)"
        echo "- **Approx downtime:** $((consecutive_down * 60))s"
        echo "- **Watchdog log tail:**"
        echo '    ```'
        tail -5 "$HOME/.openclaw/logs/watchdog.log" 2>/dev/null | sed 's/^/    /'
        echo '    ```'
        echo "- **Next steps:** run \`bash ~/Projects/openclaw/scripts/gateway-health.sh\` for full diagnosis."
        echo ""
    } >> "$ALERT_FILE"
    log "ALERT entry written: $reason"
}

# ── Main ─────────────────────────────────────────────────
load_state

if check_port; then
    # Transition from down -> up
    if [ "$last_state" = "down" ] && [ "$consecutive_down" -ge "$ALERT_THRESHOLD" ]; then
        log "RECOVERED after $consecutive_down consecutive down observations"
        {
            echo ""
            echo "## RECOVERY: Gateway is back up — $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Was down for approximately $((consecutive_down * 60)) seconds."
            echo ""
        } >> "$ALERT_FILE"
    fi
    consecutive_down=0
    last_state="up"
    # Heartbeat every 30 ticks (~30 min) so log shows we're alive
    tick_modulo=$(( $(date +%M) % 30 ))
    if [ "$tick_modulo" = "0" ]; then
        log "heartbeat: port=$GATEWAY_PORT listening OK"
    fi
else
    consecutive_down=$((consecutive_down + 1))
    last_state="down"

    if [ "$consecutive_down" -ge "$ALERT_THRESHOLD" ]; then
        now=$(date +%s)
        elapsed_since_alert=$((now - last_alert_ts))
        if [ "$last_alert_ts" = "0" ] || [ "$elapsed_since_alert" -ge "$ALERT_REPEAT_SECS" ]; then
            log "ALERT condition: consecutive_down=$consecutive_down (threshold=$ALERT_THRESHOLD)"
            write_alert_entry "Port 18789 not listening for ~$((consecutive_down * 60))s (consecutive_down=$consecutive_down)"
            last_alert_ts="$now"
        else
            log "still down (consecutive_down=$consecutive_down), next alert in $((ALERT_REPEAT_SECS - elapsed_since_alert))s"
        fi
    elif [ "$consecutive_down" -ge "$WARN_THRESHOLD" ]; then
        log "WARN: port dead for $consecutive_down ticks"
    else
        log "down (consecutive_down=$consecutive_down)"
    fi
fi

save_state
exit 0
