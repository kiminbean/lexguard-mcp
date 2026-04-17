#!/bin/bash
# openclaw-self-update.sh — out-of-session self-update wrapper
#
# Solves the "openclaw lies about skipping updates" bug by running the
# update OUTSIDE the GLM cron session, so that:
#   1) auto-update.log gets a durable JSONL event (#3 in plan)
#   2) idempotency lock prevents duplicate invocations on cron retry (#4)
#   3) from→to version is reported via direct Telegram HTTPS, independent
#      of the gateway session that was killed by self-restart (#1)
#
# Exits cleanly with JSON status on stdout so the cron session can parse it.
#
# Root cause addressed:
#   `openclaw update --yes` kills the gateway mid-session, losing the
#   upgrade report. This wrapper runs the update, waits for gateway to come
#   back, then reports separately.

set -u  # -e would hide lock release

# ─── Configuration ──────────────────────────────────────
LOG_DIR="$HOME/.openclaw/logs"
AUTO_UPDATE_LOG="$LOG_DIR/auto-update.log"
WRAPPER_EVENT_LOG="$LOG_DIR/self-update-events.jsonl"
LOCK_FILE="/tmp/openclaw-self-update.lock"
IDEMPOTENCY_WINDOW_SEC=900  # 15 minutes — suppress duplicate runs
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
GATEWAY_WAIT_SEC=120        # max wait for gateway to return after update
TELEGRAM_CHAT_ID="8137155160"
CONFIG_JSON="$HOME/.openclaw/openclaw.json"
DRY_RUN=0

# Prefer nvm openclaw (matches cron env: version 2026.4.15+)
if [ -x "$HOME/.nvm/versions/node/v22.22.1/bin/openclaw" ]; then
    OPENCLAW_BIN="$HOME/.nvm/versions/node/v22.22.1/bin/openclaw"
    export PATH="$HOME/.nvm/versions/node/v22.22.1/bin:$PATH"
elif command -v openclaw >/dev/null 2>&1; then
    OPENCLAW_BIN="$(command -v openclaw)"
else
    printf '{"status":"error","reason":"openclaw binary not found"}\n'
    exit 2
fi

# ─── Argument parsing ───────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--dry-run]

Runs openclaw self-update safely. Emits JSON on stdout:
  {"status":"upgraded","from":"X","to":"Y","durationMs":N}
  {"status":"already-latest","version":"X"}
  {"status":"skipped-recent","ranAt":"..."}    # within 15 min window
  {"status":"locked","pid":N}                  # another run in progress
  {"status":"failed","reason":"...","stage":"..."}

Events are appended as JSONL to:
  $WRAPPER_EVENT_LOG

Telegram notification is sent (unless --dry-run) on upgrade success/failure.
EOF
            exit 0
            ;;
    esac
done

mkdir -p "$LOG_DIR"

# ─── Structured event logger ────────────────────────────
log_event() {
    # log_event <eventType> [<extraJsonFragment>]
    local event="$1"
    local extra="${2:-}"
    local ts_ms
    ts_ms=$(python3 -c 'import time;print(int(time.time()*1000))')
    local ts_iso
    ts_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local base
    base=$(printf '{"ts":%s,"iso":"%s","event":"%s","dryRun":%s' \
            "$ts_ms" "$ts_iso" "$event" "$([ $DRY_RUN -eq 1 ] && echo true || echo false)")
    if [ -n "$extra" ]; then
        printf '%s,%s}\n' "$base" "$extra" >> "$WRAPPER_EVENT_LOG"
    else
        printf '%s}\n' "$base" >> "$WRAPPER_EVENT_LOG"
    fi
    # Human-readable mirror in auto-update.log
    printf '[%s] [wrapper] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$event" "$extra" >> "$AUTO_UPDATE_LOG"
}

# ─── JSON escape helper ─────────────────────────────────
json_escape() {
    python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().rstrip()))'
}

# ─── Telegram notifier (out-of-session HTTPS) ───────────
send_telegram() {
    local text="$1"
    local token
    token=$(python3 -c "
import json
with open('$CONFIG_JSON') as f:
    d = json.load(f)
print(d['channels']['telegram']['botToken'])
" 2>/dev/null)
    if [ -z "$token" ]; then
        return 1
    fi
    curl -fsS --max-time 20 \
        -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        -H 'Content-Type: application/json' \
        -d "$(python3 -c "
import json,sys
print(json.dumps({'chat_id': int('$TELEGRAM_CHAT_ID'), 'text': sys.argv[1], 'parse_mode': 'Markdown'}))
" "$text")" >/dev/null 2>&1
}

# ─── Idempotency: suppress if recent successful upgrade ──
check_recent_upgrade() {
    [ -f "$WRAPPER_EVENT_LOG" ] || return 1
    local now_ms cutoff_ms
    now_ms=$(python3 -c 'import time;print(int(time.time()*1000))')
    cutoff_ms=$((now_ms - IDEMPOTENCY_WINDOW_SEC * 1000))
    # Find last "upgraded" event within window
    python3 - "$WRAPPER_EVENT_LOG" "$cutoff_ms" <<'PY' 2>/dev/null
import json, sys
path, cutoff = sys.argv[1], int(sys.argv[2])
last = None
try:
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("event") in ("upgraded", "already-latest") and d.get("ts", 0) >= cutoff:
                if d.get("dryRun"):
                    continue
                last = d
except FileNotFoundError:
    sys.exit(1)
if last:
    print(json.dumps(last))
    sys.exit(0)
sys.exit(1)
PY
}

recent=$(check_recent_upgrade || true)
if [ -n "$recent" ]; then
    ran_iso=$(printf '%s' "$recent" | python3 -c 'import json,sys;print(json.loads(sys.stdin.read()).get("iso",""))')
    from_v=$(printf '%s' "$recent" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());print(d.get("from",d.get("version","")))')
    to_v=$(printf '%s' "$recent" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());print(d.get("to",d.get("version","")))')
    log_event "skipped-recent" "\"ranAt\":\"$ran_iso\",\"from\":\"$from_v\",\"to\":\"$to_v\""
    printf '{"status":"skipped-recent","ranAt":"%s","from":"%s","to":"%s"}\n' "$ran_iso" "$from_v" "$to_v"
    exit 0
fi

# ─── Lock (process-level idempotency) ───────────────────
if [ -f "$LOCK_FILE" ]; then
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        log_event "locked" "\"holderPid\":$lock_pid"
        printf '{"status":"locked","pid":%s}\n' "$lock_pid"
        exit 0
    fi
    # Stale lock — remove
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

# ─── Stage 1: version detection ─────────────────────────
log_event "started"

current_version_raw="$("$OPENCLAW_BIN" --version 2>&1 || true)"
current_version=$(printf '%s' "$current_version_raw" | awk '{print $2}')
if [ -z "$current_version" ]; then
    log_event "failed" "\"stage\":\"version-detect\",\"output\":$(printf '%s' "$current_version_raw" | json_escape)"
    printf '{"status":"failed","reason":"cannot detect current version","stage":"version-detect"}\n'
    exit 1
fi

dry_json=$("$OPENCLAW_BIN" update --dry-run --json 2>&1 || true)
target_version=$(printf '%s' "$dry_json" | python3 -c '
import json,sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get("targetVersion",""))
except Exception:
    print("")
')

if [ -z "$target_version" ]; then
    log_event "failed" "\"stage\":\"dry-run\",\"output\":$(printf '%s' "$dry_json" | json_escape)"
    printf '{"status":"failed","reason":"dry-run did not return targetVersion","stage":"dry-run"}\n'
    exit 1
fi

# ─── Stage 2: decide ────────────────────────────────────
if [ "$current_version" = "$target_version" ]; then
    log_event "already-latest" "\"version\":\"$current_version\""
    printf '{"status":"already-latest","version":"%s"}\n' "$current_version"
    exit 0
fi

log_event "upgrade-needed" "\"from\":\"$current_version\",\"to\":\"$target_version\""

if [ $DRY_RUN -eq 1 ]; then
    printf '{"status":"dry-run","from":"%s","to":"%s"}\n' "$current_version" "$target_version"
    log_event "dry-run-finished" "\"from\":\"$current_version\",\"to\":\"$target_version\""
    exit 0
fi

# ─── Stage 3: upgrade ───────────────────────────────────
start_ms=$(python3 -c 'import time;print(int(time.time()*1000))')
update_out_file=$(mktemp /tmp/openclaw-update.XXXXXX.log)
# Intentionally run in background so wrapper survives gateway restart
# and can report afterwards. --no-restart would leave gateway dead;
# we DO want restart, so we wait for it to come back.
"$OPENCLAW_BIN" update --yes --json >"$update_out_file" 2>&1 &
update_pid=$!
wait $update_pid
update_exit=$?
update_out="$(cat "$update_out_file")"
rm -f "$update_out_file"

if [ $update_exit -ne 0 ]; then
    log_event "upgrade-failed" "\"from\":\"$current_version\",\"to\":\"$target_version\",\"exitCode\":$update_exit,\"output\":$(printf '%s' "$update_out" | tail -c 2000 | json_escape)"
    send_telegram "❌ OpenClaw 업그레이드 실패\n\n$current_version → $target_version 시도 중 실패 (exit=$update_exit).\n수동 확인 필요: \`tail ~/.openclaw/logs/auto-update.log\`" || true
    printf '{"status":"failed","reason":"update exit %d","stage":"upgrade","from":"%s","to":"%s"}\n' "$update_exit" "$current_version" "$target_version"
    exit 1
fi

# ─── Stage 4: wait for gateway ──────────────────────────
waited=0
while [ $waited -lt $GATEWAY_WAIT_SEC ]; do
    if /usr/sbin/lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        break
    fi
    sleep 3
    waited=$((waited+3))
done
gateway_up=0
if /usr/sbin/lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    gateway_up=1
fi

# Re-detect version post-upgrade
new_version_raw="$("$OPENCLAW_BIN" --version 2>&1 || true)"
new_version=$(printf '%s' "$new_version_raw" | awk '{print $2}')
end_ms=$(python3 -c 'import time;print(int(time.time()*1000))')
duration=$((end_ms - start_ms))

# ─── Stage 5: notify ────────────────────────────────────
log_event "upgraded" "\"from\":\"$current_version\",\"to\":\"$new_version\",\"durationMs\":$duration,\"gatewayUp\":$([ $gateway_up -eq 1 ] && echo true || echo false)"

gateway_note=""
[ $gateway_up -eq 0 ] && gateway_note=" ⚠️ 게이트웨이 포트 미응답 (watchdog 복구 대기)"

send_telegram "✅ OpenClaw 자동 업데이트 완료

$current_version → $new_version
소요: $((duration/1000))초$gateway_note" || log_event "telegram-failed" ""

printf '{"status":"upgraded","from":"%s","to":"%s","durationMs":%d,"gatewayUp":%s}\n' \
    "$current_version" "$new_version" "$duration" "$([ $gateway_up -eq 1 ] && echo true || echo false)"
exit 0
