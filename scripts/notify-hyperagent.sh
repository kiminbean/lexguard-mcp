#!/bin/bash
# notify-hyperagent.sh — HyperAgent 루프 결과를 Telegram으로 직접 전달
#
# 왜 필요한가:
# - 크론 payload의 "간략히 보고"만으로는 lastDelivered가 false로 남음
# - 게이트웨이 재시작 중에도 전달 보장을 위해 api.telegram.org에 직접 POST
#
# 사용: notify-hyperagent.sh [--mode daily|weekly]

set -euo pipefail

MODE="${1:-daily}"
WORKSPACE="$HOME/Projects/openclaw"
MEMORY="$WORKSPACE/memory"
STATE_FILE="$MEMORY/learning-state.json"
CONFIG_JSON="$HOME/.openclaw/openclaw.json"
LOG_DIR="$HOME/.openclaw/logs"
NOTIFY_LOG="$LOG_DIR/hyperagent-notify.jsonl"

TELEGRAM_CHAT_ID="8137155160"

mkdir -p "$LOG_DIR"

log_event() {
    local event="$1"
    shift
    local ts_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
    local iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local line="{\"ts\":$ts_ms,\"iso\":\"$iso\",\"event\":\"$event\",\"mode\":\"$MODE\""
    for arg in "$@"; do
        line="$line,$arg"
    done
    line="$line}"
    echo "$line" >> "$NOTIFY_LOG"
}

json_escape() {
    python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))' <<< "$1"
}

get_telegram_token() {
    if [ ! -f "$CONFIG_JSON" ]; then
        return 1
    fi
    python3 -c "
import json, sys
try:
    with open('$CONFIG_JSON') as f:
        cfg = json.load(f)
    token = (
        cfg.get('channels', {}).get('telegram', {}).get('botToken')
        or cfg.get('telegram', {}).get('botToken')
        or cfg.get('notifications', {}).get('telegram', {}).get('botToken')
    )
    if token:
        print(token.strip())
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

send_telegram() {
    local message="$1"
    local token
    token=$(get_telegram_token) || {
        log_event "token-missing"
        echo '{"status":"failed","reason":"token-missing"}' >&2
        return 1
    }

    local escaped
    escaped=$(json_escape "$message")
    local payload="{\"chat_id\":\"$TELEGRAM_CHAT_ID\",\"text\":$escaped,\"parse_mode\":\"HTML\"}"

    local http_code
    http_code=$(curl -sS -o /tmp/telegram-notify-response.json -w "%{http_code}" \
        -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ]; then
        log_event "delivered" "\"httpCode\":$http_code"
        return 0
    else
        log_event "failed" "\"httpCode\":$http_code"
        return 1
    fi
}

# ─── 메인: state에서 결과 추출 → 메시지 조립 ───
compose_and_send() {
    if [ ! -f "$STATE_FILE" ]; then
        log_event "no-state"
        echo '{"status":"failed","reason":"no-state"}'
        return 1
    fi

    local message
    message=$(python3 << PYEOF
import json, os
from datetime import datetime

with open("$STATE_FILE") as f:
    s = json.load(f)

m = s.get('metrics', {})
cron = m.get('cron', {})
prop = m.get('proposals', {})
ext = m.get('externalSignal', {})
score = s.get('evolutionScore', 0)
status = s.get('evolutionStatus', '?')
history = s.get('evolutionScoreHistory', [])
prev_score = history[-2]['score'] if len(history) >= 2 else None
mode_label = "일일" if "$MODE" == "daily" else "주간"

lines = [f"🧬 <b>HyperAgent v3 {mode_label} 진화</b>"]
lines.append("")
lines.append(f"📊 <b>종합</b>: {score}/100 {status}")
if prev_score is not None:
    delta = score - prev_score
    arrow = "▲" if delta > 0 else ("▼" if delta < 0 else "—")
    lines.append(f"  이전: {prev_score} → 현재: {score} ({arrow}{abs(delta)})")
lines.append("")
lines.append(f"📡 <b>크론 건강도</b>")
lines.append(f"  • 성공률 {cron.get('successRate',0):.0f}% | 전달률 {cron.get('deliveryRate',0):.0f}%")
lines.append(f"  • 활성 {cron.get('active',0)}/{cron.get('total',0)} | 임계 {cron.get('critical',0)}개")
if cron.get('recoveryEvents',0) or cron.get('regressionEvents',0):
    lines.append(f"  • 복구 {cron['recoveryEvents']}건 / 퇴행 {cron['regressionEvents']}건")
lines.append("")
lines.append(f"💡 <b>제안</b>")
lines.append(f"  • pending {prop.get('pending',0)} | applied {prop.get('applied',0)} | 소진율 {prop.get('attritionRate',0):.0f}%")

proposals = s.get('metacognitiveProposals', [])
high = [p for p in proposals if p.get('priority') == 'high']
if high:
    lines.append("")
    lines.append(f"🔴 <b>우선 제안 ({len(high)}건)</b>")
    for p in high[:3]:
        lines.append(f"  • {p.get('id')}: {p.get('action','')[:60]}")

if ext.get('lastFailureDate'):
    last = datetime.strptime(ext['lastFailureDate'], '%Y-%m-%d')
    days = (datetime.now() - last).days
    if days >= 14:
        lines.append("")
        lines.append(f"⚠️ 외부신호 정체 ({days}일)")

print("\n".join(lines))
PYEOF
)

    if [ -z "$message" ]; then
        log_event "compose-failed"
        echo '{"status":"failed","reason":"compose-failed"}'
        return 1
    fi

    log_event "started" "\"msgLen\":${#message}"
    if send_telegram "$message"; then
        echo '{"status":"delivered"}'
        return 0
    else
        echo '{"status":"failed","reason":"telegram-error"}'
        return 1
    fi
}

compose_and_send
