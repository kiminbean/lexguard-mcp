#!/bin/bash
# openclaw-watchdog.sh v2 — Multi-layer recovery watchdog for OpenClaw Gateway
#
# Defense layers (checked in order):
#   L0 checks: launchd registration -> process -> TCP port
#   L1 recovery: launchctl kickstart -k (SIGTERM + restart)
#   L2 recovery: launchctl bootout + bootstrap (full re-registration)
#   L3 recovery: force kill lingering PIDs + bootstrap (nuclear)
#
# Safety:
#   - flock single instance (prevents duplicate runs from crontab + launchd)
#   - NEVER exits 1 on recoverable state (avoids external-watchdog throttle)
#   - `set -u` but NOT `set -e` so individual check failures don't abort recovery
#   - Logs to ~/.openclaw/logs/watchdog.log (not repo memory/) to avoid bloat

set -u

LOG_FILE="$HOME/.openclaw/logs/watchdog.log"
LOCK_FILE="/tmp/openclaw-watchdog.lock"
GATEWAY_LABEL="ai.openclaw.gateway"
GATEWAY_PLIST="$HOME/Library/LaunchAgents/${GATEWAY_LABEL}.plist"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
UID_NUM="$(id -u)"

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# Log rotation (20MB)
if [ -f "$LOG_FILE" ]; then
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    [ "$size" -gt 20971520 ] && mv "$LOG_FILE" "${LOG_FILE}.prev"
fi

# Single-instance guard (macOS: no flock; use PID file)
if [ -f "$LOCK_FILE" ]; then
    existing_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        log "another watchdog instance running (pid=$existing_pid) — skip"
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

# ── Checks ─────────────────────────────────────────────────
check_launchd() {
    launchctl list 2>/dev/null | awk '{print $3}' | grep -Fxq "$GATEWAY_LABEL"
}
check_process() {
    pgrep -f "openclaw.*gateway|node .*openclaw/dist/index.js.*gateway" >/dev/null 2>&1
}
check_port() {
    lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN >/dev/null 2>&1
}

# ── Recovery ───────────────────────────────────────────────
recover_kickstart() {
    log "L1: launchctl kickstart -k"
    launchctl kickstart -k "gui/${UID_NUM}/${GATEWAY_LABEL}" >>"$LOG_FILE" 2>&1 || true
}
recover_bootstrap() {
    log "L2: bootout + bootstrap"
    launchctl bootout "gui/${UID_NUM}/${GATEWAY_LABEL}" >>"$LOG_FILE" 2>&1 || true
    sleep 1
    launchctl bootstrap "gui/${UID_NUM}" "$GATEWAY_PLIST" >>"$LOG_FILE" 2>&1 || true
    launchctl enable "gui/${UID_NUM}/${GATEWAY_LABEL}" >>"$LOG_FILE" 2>&1 || true
    launchctl kickstart "gui/${UID_NUM}/${GATEWAY_LABEL}" >>"$LOG_FILE" 2>&1 || true
}
recover_nuclear() {
    log "L3: nuclear (pkill -9 + bootstrap)"
    pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
    sleep 2
    recover_bootstrap
}

wait_for_port() {
    local timeout="${1:-10}"; local t=0
    while [ "$t" -lt "$timeout" ]; do
        check_port && return 0
        sleep 1; t=$((t + 1))
    done
    return 1
}

# ── Main tick ──────────────────────────────────────────────
log "=== tick ==="

if [ ! -f "$GATEWAY_PLIST" ]; then
    log "FATAL: plist missing at $GATEWAY_PLIST"
    exit 0
fi

registered="no"; process="no"; port="no"
check_launchd && registered="yes"
check_process && process="yes"
check_port && port="yes"
log "state: launchd=$registered process=$process port=$port"

# Healthy path
if [ "$port" = "yes" ] && [ "$registered" = "yes" ]; then
    log "healthy"
    exit 0
fi

# Not registered → bootstrap
if [ "$registered" = "no" ]; then
    log "not registered — recovering"
    if [ "$process" = "yes" ]; then
        recover_nuclear
    else
        recover_bootstrap
    fi
    if wait_for_port 15; then
        log "RECOVERED (bootstrap)"
    else
        log "WARN: port still dead after bootstrap"
    fi
    exit 0
fi

# Registered but dead → kickstart → bootstrap → nuclear
if [ "$registered" = "yes" ] && [ "$port" = "no" ]; then
    log "registered but port dead — kickstart"
    recover_kickstart
    if wait_for_port 10; then
        log "RECOVERED (kickstart)"
        exit 0
    fi
    log "kickstart failed — bootstrap"
    recover_bootstrap
    if wait_for_port 15; then
        log "RECOVERED (bootstrap)"
        exit 0
    fi
    log "bootstrap failed — nuclear"
    recover_nuclear
    if wait_for_port 15; then
        log "RECOVERED (nuclear)"
    else
        log "FATAL: all recovery layers failed"
    fi
fi

log "tick complete"
exit 0
