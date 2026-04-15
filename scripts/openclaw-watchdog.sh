#!/bin/bash
# openclaw-watchdog.sh v3.2 — Multi-layer recovery watchdog for OpenClaw Gateway
#
# v3.2 additions over v3.1 (2026-04-15 22:30 KST):
#   - Layer 2: SHA256 self-integrity verification at every tick.
#     Expected digest: ~/.openclaw/watchdog-integrity.sha256 (seeded manually).
#     Mismatch => refuse to run any recovery, write ALERT.md, exit 0.
#   - Layer 3: Rolling SIGTERM budget (10 per 3600s).
#     Budget exhausted => refuse to send any more SIGTERMs this hour,
#     write ALERT.md, exit 0. Prevents v2-style kill-loop amplification.
#
# v3.1 fixes from v2 (kill-loop root cause):
#   - CRITICAL: `lsof` is at /usr/sbin/lsof on macOS; plist PATH omits /usr/sbin.
#     Both `export PATH=...` at top AND absolute path in check_port().
#   - wait_for_port 10/15/15s -> 45/60/60s (gateway needs ~15-20s to bind)
#   - Young-process gate: process<60s old -> wait, don't SIGTERM
#   - Inter-layer cooldowns: 30s L1->L2, 45s L2->L3
#   - Nuclear cooldown: 900s between L3 attempts
#   - launchd_loaded pre-check (avoid I/O error cascade)
#   - L2 no longer inner-kickstarts (removes an extra SIGTERM)
#
# Stakes: see memory/project_gateway_stakes.md. A regression here burns the
# Mac mini. Keep SIGTERM count low, rely on logs NOT on appearances, ALWAYS
# test check_* functions under plist PATH before declaring anything fixed.

# Defense-in-depth #1: extend PATH so /usr/sbin utilities are resolvable.
export PATH="$PATH:/usr/sbin:/sbin"

set -u

LOG_FILE="$HOME/.openclaw/logs/watchdog.log"
LOCK_FILE="/tmp/openclaw-watchdog.lock"
NUCLEAR_LOCK="/tmp/openclaw-watchdog.nuclear.ts"
SIGTERM_HISTORY="/tmp/openclaw-watchdog.sigterms"
INTEGRITY_FILE="$HOME/.openclaw/watchdog-integrity.sha256"
ALERT_FILE="$HOME/.openclaw/ALERT.md"
GATEWAY_LABEL="ai.openclaw.gateway"
GATEWAY_PLIST="$HOME/Library/LaunchAgents/${GATEWAY_LABEL}.plist"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
UID_NUM="$(id -u)"

NUCLEAR_COOLDOWN_SECS=900   # 15 minutes between L3 attempts
YOUNG_PROCESS_SECS=60       # processes newer than this get a grace period
YOUNG_WAIT_SECS=75          # how long to wait for a young process to bind
SIGTERM_MAX_PER_HOUR=10     # v2 did ~920/day; this caps regressions at 240/day

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

alert() {
    local reason="$1"
    local script_sha expected_sha port_ok
    script_sha=$(shasum -a 256 "$0" 2>/dev/null | awk '{print $1}')
    expected_sha=$(awk '{print $1}' "$INTEGRITY_FILE" 2>/dev/null || echo "(not set)")
    /usr/sbin/lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN >/dev/null 2>&1 && port_ok="yes" || port_ok="no"
    {
        echo ""
        echo "## ALERT: Watchdog refused to act ($(date '+%Y-%m-%d %H:%M:%S'))"
        echo ""
        echo "- **Reason:** $reason"
        echo "- **Script:** $0"
        echo "- **Script SHA256:** $script_sha"
        echo "- **Expected SHA256:** $expected_sha"
        echo "- **SIGTERMs in last hour:** $(sigterms_in_last_hour)"
        echo "- **Port $GATEWAY_PORT listening:** $port_ok"
        echo "- **Nuclear cooldown active:** $(nuclear_in_cooldown && echo yes || echo no)"
        echo ""
        echo "Run \`bash ~/Projects/openclaw/scripts/gateway-health.sh\` for full diagnosis."
        echo ""
    } >> "$ALERT_FILE"
    log "ALERT: $reason"
}

# ── Log rotation (20MB) ────────────────────────────────────
if [ -f "$LOG_FILE" ]; then
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    [ "$size" -gt 20971520 ] && mv "$LOG_FILE" "${LOG_FILE}.prev"
fi

# ── Single-instance guard (macOS: PID file, no flock) ──────
if [ -f "$LOCK_FILE" ]; then
    existing_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        log "another watchdog instance running (pid=$existing_pid) — skip"
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

# ── Layer 2: Self-integrity check ──────────────────────────
# If the integrity file is missing, warn but do not refuse (first-run setup).
# If present, a mismatch causes the watchdog to refuse recovery actions.
integrity_ok() {
    [ ! -f "$INTEGRITY_FILE" ] && return 2   # 2 = unseeded (fail-open with warn)
    local expected actual
    expected=$(awk '{print $1}' "$INTEGRITY_FILE" 2>/dev/null)
    actual=$(shasum -a 256 "$0" 2>/dev/null | awk '{print $1}')
    [ -n "$expected" ] && [ "$expected" = "$actual" ]
}

# ── Layer 3: SIGTERM budget ────────────────────────────────
sigterms_in_last_hour() {
    [ ! -f "$SIGTERM_HISTORY" ] && { echo 0; return; }
    local now cutoff
    now=$(date +%s)
    cutoff=$((now - 3600))
    awk -v c="$cutoff" '$1 > c { count++ } END { print count+0 }' "$SIGTERM_HISTORY"
}

record_sigterm() {
    local now cutoff
    now=$(date +%s)
    cutoff=$((now - 3600))
    echo "$now" >> "$SIGTERM_HISTORY"
    # Trim entries older than 1 hour to keep file bounded.
    awk -v c="$cutoff" '$1 > c' "$SIGTERM_HISTORY" > "${SIGTERM_HISTORY}.tmp" \
        && mv "${SIGTERM_HISTORY}.tmp" "$SIGTERM_HISTORY"
}

sigterm_budget_ok() {
    local count
    count=$(sigterms_in_last_hour)
    [ "$count" -lt "$SIGTERM_MAX_PER_HOUR" ]
}

# ── Checks ─────────────────────────────────────────────────
check_launchd() {
    launchctl list 2>/dev/null | awk '{print $3}' | grep -Fxq "$GATEWAY_LABEL"
}

check_process() {
    pgrep -f "openclaw.*gateway|node .*openclaw/dist/index.js.*gateway" >/dev/null 2>&1
}

check_port() {
    # Defense-in-depth #2: absolute path.
    /usr/sbin/lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN >/dev/null 2>&1
}

process_age_seconds() {
    local pid etime
    pid=$(pgrep -f "openclaw.*gateway|node .*openclaw/dist/index.js.*gateway" 2>/dev/null | head -1)
    [ -z "$pid" ] && { echo "-1"; return; }
    etime=$(ps -o etime= -p "$pid" 2>/dev/null | awk '{print $1}')
    [ -z "$etime" ] && { echo "-1"; return; }
    echo "$etime" | awk '{
        n = split($1, t, "[-:]");
        if (n == 2)      print t[1]*60    + t[2]
        else if (n == 3) print t[1]*3600  + t[2]*60   + t[3]
        else if (n == 4) print t[1]*86400 + t[2]*3600 + t[3]*60 + t[4]
        else             print 0
    }'
}

nuclear_in_cooldown() {
    [ ! -f "$NUCLEAR_LOCK" ] && return 1
    local last now diff
    last=$(cat "$NUCLEAR_LOCK" 2>/dev/null || echo 0)
    now=$(date +%s)
    diff=$((now - last))
    [ "$diff" -lt "$NUCLEAR_COOLDOWN_SECS" ]
}

launchd_loaded() {
    launchctl print "gui/${UID_NUM}/${GATEWAY_LABEL}" >/dev/null 2>&1
}

# ── Recovery ───────────────────────────────────────────────
recover_kickstart() {
    if ! sigterm_budget_ok; then
        alert "SIGTERM budget exceeded before L1 (count=$(sigterms_in_last_hour)/$SIGTERM_MAX_PER_HOUR per hour)"
        return 1
    fi
    log "L1: launchctl kickstart -k (SIGTERM+restart)"
    record_sigterm
    launchctl kickstart -k "gui/${UID_NUM}/${GATEWAY_LABEL}" >>"$LOG_FILE" 2>&1 || true
}

recover_bootstrap() {
    if launchd_loaded; then
        if ! sigterm_budget_ok; then
            alert "SIGTERM budget exceeded before L2 (count=$(sigterms_in_last_hour)/$SIGTERM_MAX_PER_HOUR per hour)"
            return 1
        fi
        log "L2: bootout + bootstrap"
        record_sigterm
        launchctl bootout "gui/${UID_NUM}/${GATEWAY_LABEL}" >>"$LOG_FILE" 2>&1 || true
        sleep 3
    else
        log "L2: bootstrap only (already unloaded)"
    fi
    launchctl bootstrap "gui/${UID_NUM}" "$GATEWAY_PLIST" >>"$LOG_FILE" 2>&1 || true
    launchctl enable "gui/${UID_NUM}/${GATEWAY_LABEL}" >>"$LOG_FILE" 2>&1 || true
}

recover_nuclear() {
    if ! sigterm_budget_ok; then
        alert "SIGTERM budget exceeded before L3 (count=$(sigterms_in_last_hour)/$SIGTERM_MAX_PER_HOUR per hour)"
        return 1
    fi
    log "L3: nuclear (pkill -9 + bootstrap)"
    date +%s > "$NUCLEAR_LOCK"
    record_sigterm
    pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
    sleep 3
    recover_bootstrap
}

wait_for_port() {
    local timeout="${1:-10}" t=0
    while [ "$t" -lt "$timeout" ]; do
        check_port && return 0
        sleep 1; t=$((t + 1))
    done
    return 1
}

# ── Main tick ──────────────────────────────────────────────
log "=== tick ==="

# Integrity check before doing anything that can affect the gateway.
integrity_ok
case $? in
    0) : ;;
    2) log "WARN: integrity file missing at $INTEGRITY_FILE — skipping check (first-run mode)" ;;
    *) alert "Script integrity check failed (SHA256 mismatch) — refusing to act"; exit 0 ;;
esac

if [ ! -f "$GATEWAY_PLIST" ]; then
    alert "Gateway plist missing at $GATEWAY_PLIST"
    exit 0
fi

registered="no"; process="no"; port="no"; age="-1"
check_launchd && registered="yes"
check_process && process="yes"
check_port     && port="yes"
age=$(process_age_seconds)
log "state: launchd=$registered process=$process port=$port pid_age=${age}s sigterm_1h=$(sigterms_in_last_hour)"

# Healthy path — fastest exit
if [ "$port" = "yes" ] && [ "$registered" = "yes" ]; then
    log "healthy"
    exit 0
fi

# Young-process grace — gateway is mid-startup, don't kill
if [ "$process" = "yes" ] && [ "$port" = "no" ] && [ "$age" -ge 0 ] && [ "$age" -lt "$YOUNG_PROCESS_SECS" ]; then
    log "process young (${age}s < ${YOUNG_PROCESS_SECS}s) — waiting ${YOUNG_WAIT_SECS}s"
    if wait_for_port "$YOUNG_WAIT_SECS"; then
        log "RECOVERED (waited for young process)"
    else
        log "WARN: young process didn't bind in ${YOUNG_WAIT_SECS}s — will re-evaluate next tick"
    fi
    exit 0
fi

# Not registered -> single bootstrap (no SIGTERM to the gateway needed)
if [ "$registered" = "no" ]; then
    log "not registered — recovering (bootstrap only)"
    if [ "$process" = "yes" ]; then
        if nuclear_in_cooldown; then
            log "orphan process present but nuclear in cooldown — bootstrap only"
            recover_bootstrap || true
        else
            recover_nuclear || true
        fi
    else
        recover_bootstrap || true
    fi
    if wait_for_port 90; then
        log "RECOVERED (bootstrap)"
    else
        log "WARN: port still dead 90s after bootstrap — next tick will retry"
    fi
    exit 0
fi

# Registered but port dead -> escalate carefully
if [ "$registered" = "yes" ] && [ "$port" = "no" ]; then
    if nuclear_in_cooldown; then
        log "nuclear in cooldown — skipping this tick (allowing launchd KeepAlive to work)"
        exit 0
    fi

    log "registered but port dead (pid_age=${age}s) — L1 kickstart"
    recover_kickstart || { log "L1 aborted (budget)"; exit 0; }
    if wait_for_port 45; then
        log "RECOVERED (kickstart)"
        exit 0
    fi

    log "L1 failed after 45s — cooldown 30s before L2"
    sleep 30
    if wait_for_port 5; then
        log "RECOVERED (late kickstart)"
        exit 0
    fi

    recover_bootstrap || { log "L2 aborted (budget)"; exit 0; }
    if wait_for_port 60; then
        log "RECOVERED (bootstrap)"
        exit 0
    fi

    log "L2 failed after 60s — cooldown 45s before L3"
    sleep 45
    if wait_for_port 5; then
        log "RECOVERED (late bootstrap)"
        exit 0
    fi

    recover_nuclear || { log "L3 aborted (budget)"; exit 0; }
    if wait_for_port 60; then
        log "RECOVERED (nuclear)"
    else
        log "FATAL: all recovery layers failed — nuclear cooldown ${NUCLEAR_COOLDOWN_SECS}s engaged"
        alert "All recovery layers failed after full tick"
    fi
fi

log "tick complete"
exit 0
