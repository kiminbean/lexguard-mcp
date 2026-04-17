#!/bin/bash
# evolve.sh — OpenClaw 자가 진화 엔진 v3
#
# 변경점 (v3):
# - metacognitive.sh가 먼저 state['metrics']를 쓴 후 이 스크립트가 읽음 (파이프라인 순서 수정)
# - 점수 계산: 외부 효과 지표 중심 (delivery, recovery, proposal attrition)
# - 자기참조 지표(completionRate 이모지 카운트, userModelScore 키워드) 제거
# - schemaVersion: 3
#
# 사용: evolve.sh [daily|weekly]

set -euo pipefail

MODE="${1:-daily}"
WORKSPACE="$HOME/Projects/openclaw"
MEMORY="$WORKSPACE/memory"
LEARNING_STATE="$MEMORY/learning-state.json"
EVOLUTION_LOG="$MEMORY/evolution-log.md"

TODAY=$(date '+%Y-%m-%d')
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

mkdir -p "$MEMORY"

init_log() {
    if [ ! -f "$EVOLUTION_LOG" ]; then
        cat > "$EVOLUTION_LOG" << 'EOF'
# 진화 로그

_에이전트가 자가 개선한 기록입니다._

---
EOF
    fi
}

log_evolution() {
    local type="$1" desc="$2" impact="$3"
    if grep -q "## \[$TODAY\] $type" "$EVOLUTION_LOG" 2>/dev/null; then
        return 0
    fi
    {
        echo ""
        echo "## [$TODAY] $type"
        echo "- **설명**: $desc"
        echo "- **영향**: $impact"
        echo "- **모드**: $MODE"
    } >> "$EVOLUTION_LOG"
}

# ─── 진화 점수 v3 (외부 효과 기반) ───
calculate_score() {
    echo ""
    echo "🧬 진화 점수 v3 (외부 효과 기반)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

    python3 << PYEOF
import json, os
from datetime import datetime

state_file = "$LEARNING_STATE"
state = {}
if os.path.exists(state_file):
    with open(state_file) as f:
        state = json.load(f)

m = state.get('metrics', {})
if not m:
    print("  ⚠️ metrics 없음 — metacognitive.sh를 먼저 실행하세요")
    exit(0)

cron = m.get('cron', {})
prop = m.get('proposals', {})
ext = m.get('externalSignal', {})
stab = m.get('stability', {})
mem = m.get('memory', {})

score = 0
details = []

# 1. 전달률 (0~30점) — v3 최중요
dr = cron.get('deliveryRate', 0)
p = int(dr * 0.3)
score += p
details.append(f"전달률: {dr:.0f}% → {p}점 (max 30)")

# 2. 임계 에러 0 (0~20점)
crit = cron.get('critical', 0)
if crit == 0:
    score += 20; details.append(f"임계에러: 0개 → 20점")
elif crit == 1:
    score += 10; details.append(f"임계에러: 1개 → 10점")
else:
    details.append(f"임계에러: {crit}개 → 0점")

# 3. 성공률 (0~15점)
sr = cron.get('successRate', 0)
p = int(sr * 0.15)
score += p
details.append(f"성공률: {sr:.0f}% → {p}점 (max 15)")

# 4. 제안 소진율 (0~15점) — 루프 폐쇄 지표
attr = prop.get('attritionRate', 0)
pending_count = prop.get('pending', 0)
applied_count = prop.get('applied', 0)
if pending_count + applied_count == 0:
    p = 10  # 제안 자체가 없으면 중립 (모두 양호)
    details.append(f"제안소진: 제안없음 → {p}점 (중립)")
else:
    p = int(attr * 0.15)
    score += p
    details.append(f"제안소진: {attr:.0f}% (applied {applied_count}/pending {pending_count}) → {p}점")
    score -= 0  # 이미 + 되어있음

# 5. 에러 회복 vs 퇴행 (0~10점)
recov = cron.get('recoveryEvents', 0)
regr = cron.get('regressionEvents', 0)
net = recov - regr
if net >= 2:
    p = 10
elif net >= 0:
    p = 5
else:
    p = 0
score += p
details.append(f"회복/퇴행: +{recov}/-{regr} → {p}점")

# 6. 외부 신호 신선도 (0~5점)
days_since = None
if ext.get('lastFailureDate'):
    last = datetime.strptime(ext['lastFailureDate'], '%Y-%m-%d')
    days_since = (datetime.now() - last).days

if days_since is None:
    p = 0
    details.append(f"외부신호: 기록 없음 → 0점")
elif days_since <= 7:
    p = 5; details.append(f"외부신호: {days_since}일 전 → 5점 (신선)")
elif days_since <= 14:
    p = 3; details.append(f"외부신호: {days_since}일 전 → 3점")
else:
    p = 0; details.append(f"외부신호: {days_since}일 전 → 0점 (정체)")
score += p

# 7. 스크립트 안정성 (0~5점) — 너무 잦은 수정 감점
churn = stab.get('churnThisRun', 0)
if churn == 0:
    p = 5; details.append(f"안정성: 변경없음 → 5점")
elif churn <= 2:
    p = 3; details.append(f"안정성: {churn}건 변경 → 3점")
else:
    p = 0; details.append(f"안정성: {churn}건 변경(과다) → 0점")
score += p

score = max(0, min(score, 100))

# 히스토리
history = state.get('evolutionScoreHistory', [])
history.append({
    'date': '$TODAY',
    'score': score,
    'delivery': dr,
    'success': sr,
    'attrition': attr,
    'net': net,
    'schemaVersion': 3,
})
history = history[-30:]
state['evolutionScoreHistory'] = history

# 트렌드
trend = "➡️ 안정"
if len(history) >= 3:
    recent = sum(h['score'] for h in history[-3:]) / 3
    older = sum(h['score'] for h in history[-6:-3]) / 3 if len(history) >= 6 else recent
    delta = recent - older
    if delta > 5: trend = "📈 상승"
    elif delta < -5: trend = "📉 하락"

print(f"  점수 구성:")
for d in details:
    print(f"    • {d}")
print()
print(f"  🧬 종합: {score}/100 ({trend})")

if score >= 80:
    status = "🌟 고도화"
elif score >= 60:
    status = "📈 성장 중"
elif score >= 40:
    status = "🌱 개선 여지"
else:
    status = "⚠️ 주의 필요"
print(f"  상태: {status}")

state['evolutionScore'] = score
state['evolutionStatus'] = status
state['lastEvolution'] = '$TIMESTAMP'
state['schemaVersion'] = 3

with open(state_file, 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
PYEOF
}

# ─── 메인 ───
init_log
case "$MODE" in
    daily|weekly)
        echo "🧬 진화 엔진 v3 — ${MODE} 모드 ($TODAY)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
        calculate_score
        if [ "$MODE" = "weekly" ]; then
            log_evolution "주간 진화 v3" "외부효과 기반 점수 계산" "v3 지표 체계"
        fi
        ;;
    *)
        echo "Usage: evolve.sh [daily|weekly]"
        exit 1
        ;;
esac

echo ""
echo "✅ 진화 엔진 v3 완료"
