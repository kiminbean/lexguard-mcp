#!/bin/bash
# evolve.sh — OpenClaw 자가 진화 엔진 v4
#
# 변경점 (v4, 2026-04-18 DGM-H 업그레이드):
# - benchmarkQuality 점수 컴포넌트 추가 (10점) — benchmark.sh passRate 반영
# - 가중치 재분배: deliveryRate 30→25, proposalAttrition 15→10 (benchmark 10 신설)
# - archive 아카이브 노드 최신점수 sample 통합 (trend 계산에 archive score 활용)
# - v3 버그 수정: 제안없음 케이스 중립 점수(7) 실제 score에 가산
# - schemaVersion: 4
#
# 변경점 (v3 기준, 유지):
# - metacognitive.sh가 먼저 state['metrics']를 쓴 후 이 스크립트가 읽음 (파이프라인 순서 수정)
# - 점수 계산: 외부 효과 지표 중심 (delivery, recovery, proposal attrition)
# - 자기참조 지표(completionRate 이모지 카운트, userModelScore 키워드) 제거
#
# 사용: evolve.sh [daily|weekly]

set -euo pipefail

MODE="${1:-daily}"
WORKSPACE="$HOME/Projects/openclaw"
MEMORY="$WORKSPACE/memory"
LEARNING_STATE="$MEMORY/learning-state.json"
EVOLUTION_LOG="$MEMORY/evolution-log.md"
BENCHMARK_FILE="$MEMORY/benchmark-results.json"
ARCHIVE_INDEX="$MEMORY/agent-archive/index.json"

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

# ─── 진화 점수 v4 (외부 효과 + 벤치마크 + archive 통합) ───
calculate_score() {
    echo ""
    echo "🧬 진화 점수 v4 (DGM-H: 외부효과 + 벤치마크)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

    python3 << PYEOF
import json, os
from datetime import datetime

state_file = "$LEARNING_STATE"
benchmark_file = "$BENCHMARK_FILE"
archive_index = "$ARCHIVE_INDEX"

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

score = 0
details = []

# 1. 전달률 (0~25점) — v4 조정 (30→25, benchmark에 5점 양도)
dr = cron.get('deliveryRate', 0)
p = int(dr * 0.25)
score += p
details.append(f"전달률: {dr:.0f}% → {p}점 (max 25)")

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

# 4. 제안 소진율 (0~10점) — v4 조정 (15→10, benchmark에 5점 양도)
attr = prop.get('attritionRate', 0)
pending_count = prop.get('pending', 0)
applied_count = prop.get('applied', 0)
if pending_count + applied_count == 0:
    # v3 버그 수정: score += p 누락 → 실제 가산
    p = 7  # 제안없음: 중립 70% (10 × 0.7)
    score += p
    details.append(f"제안소진: 제안없음 → {p}점 (중립)")
else:
    p = int(attr * 0.10)
    score += p
    details.append(f"제안소진: {attr:.0f}% (applied {applied_count}/pending {pending_count}) → {p}점")

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

# 7. 스크립트 안정성 (0~5점)
churn = stab.get('churnThisRun', 0)
if churn == 0:
    p = 5; details.append(f"안정성: 변경없음 → 5점")
elif churn <= 2:
    p = 3; details.append(f"안정성: {churn}건 변경 → 3점")
else:
    p = 0; details.append(f"안정성: {churn}건 변경(과다) → 0점")
score += p

# 8. 벤치마크 품질 (0~10점) — v4 신설 (DGM staged evaluation)
bench_p = 0
bench_pass_rate = None
if os.path.exists(benchmark_file):
    try:
        with open(benchmark_file) as f:
            bench_data = json.load(f)
        if bench_data:
            latest = bench_data[-1]
            bench_pass_rate = latest.get('summary', {}).get('passRate', 0)
            bench_p = int(bench_pass_rate * 0.10)
            details.append(f"벤치마크: {bench_pass_rate:.0f}% passRate → {bench_p}점 (max 10)")
        else:
            details.append(f"벤치마크: 기록 없음 → 0점")
    except Exception as e:
        details.append(f"벤치마크: 읽기 실패 → 0점")
else:
    details.append(f"벤치마크: 미실행 → 0점")
score += bench_p

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
    'benchmark': bench_pass_rate if bench_pass_rate is not None else 0,
    'schemaVersion': 4,
})
history = history[-30:]
state['evolutionScoreHistory'] = history

# 트렌드 (archive 노드 점수 sample 활용)
trend = "➡️ 안정"
archive_scores = []
if os.path.exists(archive_index):
    try:
        with open(archive_index) as f:
            idx = json.load(f)
        archive_scores = [n.get('score', 0) for n in idx.get('nodes', [])[-5:]]
    except:
        pass

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

if archive_scores:
    avg_archive = sum(archive_scores) / len(archive_scores)
    print(f"  📚 archive 최근 {len(archive_scores)}노드 평균: {avg_archive:.1f}")

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
state['schemaVersion'] = 4

with open(state_file, 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
PYEOF
}

# ─── 메인 ───
init_log
case "$MODE" in
    daily|weekly)
        echo "🧬 진화 엔진 v4 — ${MODE} 모드 ($TODAY)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
        calculate_score
        if [ "$MODE" = "weekly" ]; then
            log_evolution "주간 진화 v4" "DGM-H: 외부효과 + 벤치마크 기반 점수 계산" "v4 지표 체계"
        fi
        ;;
    *)
        echo "Usage: evolve.sh [daily|weekly]"
        exit 1
        ;;
esac

echo ""
echo "✅ 진화 엔진 v4 완료"
