#!/bin/bash
# cron-audit.sh — 크론잡 성과 감사 v3
#
# 변경점 (v3):
# - openclaw cron list --json 으로 정확한 데이터 소스
# - lastDurationMs 단위 버그 수정 (이미 ms인데 *1000 → 제거)
# - lastDelivered 실제 state에서 읽음 (하드코딩 제거)
# - consecutiveErrors >= 5 이면 auto-disable (명시적 whitelist 예외)
#
# 사용: cron-audit.sh [--auto-disable]

set -euo pipefail

WORKSPACE="$HOME/Projects/openclaw"
AUDIT_FILE="$WORKSPACE/memory/cron-audit.json"
DISABLE_LOG="$WORKSPACE/memory/cron-disable-log.md"
TODAY=$(date '+%Y-%m-%d')
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

AUTO_DISABLE=false
if [ "${1:-}" = "--auto-disable" ]; then
    AUTO_DISABLE=true
fi

# auto-disable에서 제외할 크론 (사용자 명시 보호 목록)
NEVER_DISABLE=(
    "17bd5db1-6ecf-449f-9997-dd9378ea016a"  # Gateway Watchdog
    "7e932a00-e857-47d9-94d1-23dd0ede2357"  # HyperAgents 진화 루프 (자기 자신)
    "e6bbc483-9ca0-4c71-a7fe-26d066c1ff1a"  # HyperAgents 주간
    "1398b2d0-c98e-4bee-b079-27346132ab19"  # OpenClaw 자동 업데이트
)

is_protected() {
    local id="$1"
    for p in "${NEVER_DISABLE[@]}"; do
        [ "$id" = "$p" ] && return 0
    done
    return 1
}

echo "📊 크론잡 성과 감사 v3 — $TODAY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

JOBS_JSON_FILE=$(mktemp)
trap "rm -f $JOBS_JSON_FILE" EXIT
openclaw cron list --json 2>/dev/null > "$JOBS_JSON_FILE" || echo '{"jobs":[]}' > "$JOBS_JSON_FILE"

# disable 후보 ID 목록 추출 (프로텍션 적용)
DISABLE_CANDIDATES=$(NEVER_DISABLE_STR="${NEVER_DISABLE[*]}" JOBS_FILE="$JOBS_JSON_FILE" python3 << 'PYEOF'
import json, os
with open(os.environ['JOBS_FILE']) as f:
    data = json.load(f)
protected = os.environ.get('NEVER_DISABLE_STR', '').split()

candidates = []
for job in data.get('jobs', []):
    st = job.get('state', {})
    ce = st.get('consecutiveErrors', 0)
    enabled = job.get('enabled', True)
    jid = job.get('id', '')
    if enabled and ce >= 5 and jid not in protected:
        candidates.append(jid)

print(' '.join(candidates))
PYEOF
)

# 감사 리포트 출력 + JSON 저장
JOBS_FILE="$JOBS_JSON_FILE" AUDIT_FILE="$AUDIT_FILE" TODAY="$TODAY" TIMESTAMP="$TIMESTAMP" python3 << 'PYEOF'
import json, os
from datetime import datetime

with open(os.environ['JOBS_FILE']) as f:
    data = json.load(f)
audit_file = os.environ['AUDIT_FILE']
today = os.environ['TODAY']
timestamp = os.environ['TIMESTAMP']
jobs = data.get('jobs', [])

results = []
for job in jobs:
    name = job.get('name', 'Unknown')
    jid = job.get('id', '')
    enabled = job.get('enabled', True)
    st = job.get('state', {})
    ce = st.get('consecutiveErrors', 0)
    last_status = st.get('lastRunStatus') or st.get('lastStatus', 'unknown')
    last_dur_ms = st.get('lastDurationMs', 0)
    delivered = st.get('lastDelivered', False)
    last_run = st.get('lastRunAtMs', 0)

    # 가치 평가
    if not enabled:
        value = '⚫ DISABLED'
    elif ce >= 5:
        value = '🔴 심각'
    elif ce >= 3:
        value = '🔴 문제'
    elif ce >= 1:
        value = '🟡 주의'
    elif last_status == 'ok' and delivered:
        value = '🟢 활성'
    elif last_status == 'ok':
        value = '⚪ 자동'
    else:
        value = '❓ 미확인'

    results.append({
        'id': jid,
        'name': name,
        'value': value,
        'enabled': enabled,
        'errors': ce,
        'duration_s': round(last_dur_ms / 1000, 1),  # v3: *1000 제거
        'delivered': delivered,
        'lastRunAtMs': last_run,
    })

active = [r for r in results if r['enabled']]
severe = [r for r in results if '🔴' in r['value']]
warning = [r for r in results if '🟡' in r['value']]

print(f"총 {len(results)}개 (활성 {len(active)}, 문제 {len(severe)}, 주의 {len(warning)})")
print()

if severe:
    print("🔴 심각/문제:")
    for r in severe:
        print(f"  {r['value']} {r['name']} (err={r['errors']}, dur={r['duration_s']}s)")
    print()

if warning:
    print("🟡 주의:")
    for r in warning:
        print(f"  {r['value']} {r['name']} (err={r['errors']})")
    print()

# JSON 누적 저장
audit = []
if os.path.exists(audit_file):
    try:
        with open(audit_file) as f: audit = json.load(f)
    except: pass

audit.append({
    'date': today,
    'timestamp': timestamp,
    'total': len(results),
    'active': len(active),
    'severe': len(severe),
    'warning': len(warning),
    'schemaVersion': 3,
    'details': results,
})
audit = audit[-30:]
with open(audit_file, 'w') as f:
    json.dump(audit, f, indent=2, ensure_ascii=False)
PYEOF

# Auto-disable 실행 (옵션일 때만)
if [ "$AUTO_DISABLE" = true ] && [ -n "$DISABLE_CANDIDATES" ]; then
    echo ""
    echo "🚫 Auto-disable 실행 (consecutiveErrors >= 5)"

    # 로그 헤더 보장
    if [ ! -f "$DISABLE_LOG" ]; then
        echo "# 크론 자동 비활성화 로그" > "$DISABLE_LOG"
        echo "" >> "$DISABLE_LOG"
    fi

    for jid in $DISABLE_CANDIDATES; do
        if is_protected "$jid"; then
            echo "  🛡️ 보호됨: $jid (스킵)"
            continue
        fi
        if openclaw cron disable "$jid" >/dev/null 2>&1; then
            # 이름 찾기
            name=$(JOBS_FILE="$JOBS_JSON_FILE" JID="$jid" python3 -c "
import json, os
with open(os.environ['JOBS_FILE']) as f: d = json.load(f)
for j in d.get('jobs', []):
    if j.get('id') == os.environ['JID']:
        print(j.get('name', 'Unknown'))
        break
")
            echo "  ✅ 비활성화: $name ($jid)"
            {
                echo ""
                echo "## [$TODAY] $name"
                echo "- **ID**: \`$jid\`"
                echo "- **사유**: consecutiveErrors >= 5"
                echo "- **복구**: \`openclaw cron enable $jid\`"
            } >> "$DISABLE_LOG"
        else
            echo "  ❌ 비활성화 실패: $jid"
        fi
    done
elif [ -n "$DISABLE_CANDIDATES" ]; then
    echo ""
    echo "ℹ️ Auto-disable 후보 있음 (--auto-disable 플래그 필요):"
    for jid in $DISABLE_CANDIDATES; do
        echo "  • $jid"
    done
fi

echo ""
echo "✅ 크론 감사 v3 완료"
