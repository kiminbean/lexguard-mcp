#!/bin/bash
# gateway-health.sh — One-line health dashboard for OpenClaw gateway defense
#
# Designed to be human-runnable when the user is nervous. Shows everything
# needed to tell "healthy" from "kill-loop" at a glance.
#
# Usage:
#   bash ~/Projects/openclaw/scripts/gateway-health.sh
#
# Read-only. Never kills anything.

export PATH="$PATH:/usr/sbin:/sbin"

UID_NUM="$(id -u)"
GATEWAY_LABEL="ai.openclaw.gateway"
WATCHDOG_LABEL="ai.openclaw.gateway-watchdog"
CANARY_LABEL="ai.openclaw.gateway-canary"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

WATCHDOG_LOG="$HOME/.openclaw/logs/watchdog.log"
CANARY_LOG="$HOME/.openclaw/logs/canary.log"
SIGTERM_HISTORY="/tmp/openclaw-watchdog.sigterms"
INTEGRITY_FILE="$HOME/.openclaw/watchdog-integrity.sha256"
ALERT_FILE="$HOME/.openclaw/ALERT.md"
WATCHDOG_SCRIPT="$HOME/Projects/openclaw/scripts/openclaw-watchdog.sh"
CANARY_SCRIPT="$HOME/Projects/openclaw/scripts/openclaw-canary.sh"

c_red=$'\033[31m'
c_green=$'\033[32m'
c_yellow=$'\033[33m'
c_cyan=$'\033[36m'
c_reset=$'\033[0m'

say() { printf '%s\n' "$1"; }
hdr() { printf '\n%s== %s ==%s\n' "$c_cyan" "$1" "$c_reset"; }

# ─── 1. Gateway liveness ─────────────────────────────────
hdr "1. Gateway"
if /usr/sbin/lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    pid=$(/usr/sbin/lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN | awk 'NR==2{print $2}')
    etime=$(ps -o etime= -p "$pid" 2>/dev/null | awk '{print $1}')
    say "${c_green}UP${c_reset}  port=$GATEWAY_PORT LISTEN  pid=$pid  uptime=$etime"
else
    say "${c_red}DOWN${c_reset}  port=$GATEWAY_PORT NOT LISTENING"
fi

# ─── 2. launchd registrations ────────────────────────────
hdr "2. launchd services"
for label in "$GATEWAY_LABEL" "$WATCHDOG_LABEL" "$CANARY_LABEL"; do
    if launchctl list 2>/dev/null | awk '{print $3}' | grep -Fxq "$label"; then
        say "${c_green}registered${c_reset}  $label"
    else
        say "${c_red}MISSING${c_reset}     $label"
    fi
done

# ─── 3. Watchdog tick history (last hour) ───────────────
hdr "3. Watchdog ticks (last hour)"
if [ -f "$WATCHDOG_LOG" ]; then
    now_epoch=$(date +%s)
    cutoff=$((now_epoch - 3600))
    stats=$(awk -v c="$cutoff" '
        /^\[/ {
            # parse [YYYY-MM-DD HH:MM:SS]
            gsub(/[\[\]]/, "", $0);
            dt = $1 " " $2;
            cmd = "date -j -f \"%Y-%m-%d %H:%M:%S\" \"" dt "\" +%s 2>/dev/null";
            cmd | getline ts; close(cmd);
            if (ts < c) next;
            if ($0 ~ /=== tick ===/) ticks++;
            else if ($0 ~ / healthy$/) healthy++;
            else if ($0 ~ /RECOVERED/) recovered++;
            else if ($0 ~ /FATAL:/) fatal++;
            else if ($0 ~ /ALERT:/) alerts++;
        }
        END {
            printf "ticks=%d healthy=%d recovered=%d fatal=%d alerts=%d\n",
                ticks+0, healthy+0, recovered+0, fatal+0, alerts+0
        }
    ' "$WATCHDOG_LOG")
    ticks=$(echo "$stats" | sed -n 's/.*ticks=\([0-9]*\).*/\1/p')
    healthy=$(echo "$stats" | sed -n 's/.*healthy=\([0-9]*\).*/\1/p')
    fatal=$(echo "$stats" | sed -n 's/.*fatal=\([0-9]*\).*/\1/p')
    alerts=$(echo "$stats" | sed -n 's/.*alerts=\([0-9]*\).*/\1/p')
    if [ "${ticks:-0}" -eq 0 ]; then
        say "${c_yellow}no ticks in last hour${c_reset} (watchdog may not be running)"
    else
        ratio=$(awk -v h="${healthy:-0}" -v t="${ticks:-1}" 'BEGIN{printf "%d", h*100/t}')
        color="$c_green"
        [ "$ratio" -lt 80 ] && color="$c_red"
        [ "$ratio" -ge 80 ] && [ "$ratio" -lt 100 ] && color="$c_yellow"
        say "  $stats"
        say "  healthy ratio: ${color}${ratio}%${c_reset}"
    fi
else
    say "${c_yellow}watchdog log missing: $WATCHDOG_LOG${c_reset}"
fi

# ─── 4. SIGTERM budget ───────────────────────────────────
hdr "4. SIGTERM budget (last hour, cap=10)"
if [ -f "$SIGTERM_HISTORY" ]; then
    now_epoch=$(date +%s)
    cutoff=$((now_epoch - 3600))
    count=$(awk -v c="$cutoff" '$1 > c { n++ } END { print n+0 }' "$SIGTERM_HISTORY")
    color="$c_green"
    [ "$count" -ge 5 ] && color="$c_yellow"
    [ "$count" -ge 10 ] && color="$c_red"
    say "  ${color}${count}${c_reset} / 10"
else
    say "  ${c_green}0${c_reset} / 10 (history empty)"
fi

# ─── 5. Watchdog script integrity ────────────────────────
hdr "5. Watchdog script integrity"
if [ -f "$INTEGRITY_FILE" ] && [ -f "$WATCHDOG_SCRIPT" ]; then
    expected=$(awk '{print $1}' "$INTEGRITY_FILE")
    actual=$(shasum -a 256 "$WATCHDOG_SCRIPT" 2>/dev/null | awk '{print $1}')
    if [ "$expected" = "$actual" ]; then
        say "  ${c_green}MATCH${c_reset}  sha256=${expected:0:16}..."
    else
        say "  ${c_red}MISMATCH${c_reset}"
        say "    expected: ${expected:0:32}..."
        say "    actual:   ${actual:0:32}..."
    fi
else
    say "  ${c_yellow}integrity file not set${c_reset}"
fi

# ─── 6. Canary state ─────────────────────────────────────
hdr "6. Canary"
if [ -f "$CANARY_LOG" ]; then
    tail_line=$(tail -1 "$CANARY_LOG")
    say "  latest: $tail_line"
fi
state_file="/tmp/openclaw-canary.state"
if [ -f "$state_file" ]; then
    say "  state:"
    sed 's/^/    /' "$state_file"
fi

# ─── 7. ALERT.md status ──────────────────────────────────
hdr "7. Active alerts (~/.openclaw/ALERT.md)"
if [ -f "$ALERT_FILE" ] && [ -s "$ALERT_FILE" ]; then
    size=$(stat -f%z "$ALERT_FILE" 2>/dev/null || echo 0)
    alert_count=$(grep -c '^## ALERT:' "$ALERT_FILE" 2>/dev/null || echo 0)
    recovery_count=$(grep -c '^## RECOVERY:' "$ALERT_FILE" 2>/dev/null || echo 0)
    say "  ${c_yellow}EXISTS${c_reset}  size=${size}B  alerts=$alert_count  recoveries=$recovery_count"
    say "  last 20 lines:"
    tail -20 "$ALERT_FILE" | sed 's/^/    /'
else
    say "  ${c_green}no alerts${c_reset} (clean)"
fi

hdr "Summary"
summary_ok=1
/usr/sbin/lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN >/dev/null 2>&1 || summary_ok=0
launchctl list 2>/dev/null | awk '{print $3}' | grep -Fxq "$WATCHDOG_LABEL" || summary_ok=0
[ -s "$ALERT_FILE" ] && alert_count=$(grep -c '^## ALERT:' "$ALERT_FILE" 2>/dev/null || echo 0) && [ "$alert_count" -gt 0 ] && summary_ok=0
if [ "$summary_ok" = "1" ]; then
    say "  ${c_green}ALL SYSTEMS HEALTHY${c_reset}"
else
    say "  ${c_red}DEGRADED — investigate above${c_reset}"
fi
say ""
exit 0
