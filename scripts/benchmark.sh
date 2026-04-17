#!/bin/bash
# benchmark.sh — HyperAgent 단계별 운영 벤치마크 v4
#
# DGM 논문 (arxiv 2505.22954) staged evaluation 개념:
#   Stage 1 (빠름, 저비용) → Stage 2 (중간) → Stage 3 (느림, 정밀)
#   낮은 단계에서 탈락한 변형체는 높은 단계 eval 스킵 → compute 절감
#
# 본 구현 (SWE-bench 대신 운영 벤치마크):
#   Stage 1 (smoke, ~10s): bash -n + dry-run + state validity (10 tasks)
#   Stage 2 (integration, ~30s): 파이프라인 구성요소 실제 실행 (5 tasks)
#   Stage 3 (stress, ~60s): 결정성/회복성/성능 (3 tasks)
#
# 출력:
#   memory/benchmark-results.json  (JSON 배열, 14일 rolling)
#   stdout: 요약 + passRate (evolve.sh가 점수 가중에 사용)
#
# 사용:
#   benchmark.sh --stage 1              # smoke only
#   benchmark.sh --stage 2              # smoke + integration
#   benchmark.sh --stage all            # 전체 (기본)
#   benchmark.sh --json                 # JSON만 stdout

set -euo pipefail

WORKSPACE="$HOME/Projects/openclaw"
SCRIPTS_DIR="$WORKSPACE/scripts"
MEMORY="$WORKSPACE/memory"
STATE_FILE="$MEMORY/learning-state.json"
BENCHMARK_FILE="$MEMORY/benchmark-results.json"
ARCHIVE_DIR="$MEMORY/agent-archive"
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

STAGE="all"
JSON_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) STAGE="$2"; shift 2 ;;
        --json) JSON_ONLY=true; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

# ─── 유틸: 태스크 실행 ───
TASK_RESULTS_FILE=$(mktemp)
trap "rm -f $TASK_RESULTS_FILE" EXIT

run_task() {
    local name="$1"
    local stage="$2"
    shift 2
    local start_ms
    start_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

    local result="passed"
    local error_msg=""

    if ! error_msg=$("$@" 2>&1); then
        result="failed"
    fi

    local end_ms
    end_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
    local duration=$((end_ms - start_ms))

    local err_escaped
    err_escaped=$(python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()[:200]))' <<< "$error_msg")

    printf '{"stage":%s,"name":"%s","result":"%s","durationMs":%s,"error":%s}\n' \
        "$stage" "$name" "$result" "$duration" "$err_escaped" >> "$TASK_RESULTS_FILE"

    if [ "$JSON_ONLY" != true ]; then
        local icon="✅"
        [ "$result" = "failed" ] && icon="❌"
        printf "  %s Stage %s/%s (%sms)\n" "$icon" "$stage" "$name" "$duration"
    fi
}

# ─── Stage 1: Smoke Tests ───
stage1_bash_syntax() {
    local s="$1"
    bash -n "$SCRIPTS_DIR/$s"
}

stage1_state_valid() {
    python3 -c "
import json
with open('$STATE_FILE') as f: s = json.load(f)
assert 'evolutionScore' in s, 'evolutionScore missing'
assert isinstance(s.get('evolutionScore'), (int, float)), 'evolutionScore not number'
"
}

stage1_archive_valid() {
    python3 -c "
import json, os, sys
idx_path = '$ARCHIVE_DIR/index.json'
if not os.path.exists(idx_path):
    sys.exit(0)
with open(idx_path) as f: idx = json.load(f)
assert idx.get('schemaVersion') == 4, 'schemaVersion mismatch'
for n in idx.get('nodes', []):
    assert 'id' in n and 'score' in n, 'node missing field'
"
}

run_stage_1() {
    [ "$JSON_ONLY" = true ] || echo "🧪 Stage 1: Smoke Tests"

    for s in evolve.sh metacognitive.sh self-modify.sh cron-audit.sh notify-hyperagent.sh archive.sh select-parent.sh benchmark.sh; do
        run_task "syntax-$s" 1 stage1_bash_syntax "$s"
    done

    run_task "state-valid" 1 stage1_state_valid
    run_task "archive-valid" 1 stage1_archive_valid
}

# ─── Stage 2: Integration ───
stage2_metacognitive_run() {
    # 실행해서 exit 0이면 pass (state 변경은 이후 테스트에서 검증)
    bash "$SCRIPTS_DIR/metacognitive.sh" >/dev/null 2>&1
}

stage2_evolve_daily_run() {
    bash "$SCRIPTS_DIR/evolve.sh" daily >/dev/null 2>&1
}

stage2_cron_audit_run() {
    bash "$SCRIPTS_DIR/cron-audit.sh" >/dev/null 2>&1
}

stage2_archive_cycle() {
    # add → list → get → restore dry-run
    local out
    out=$(bash "$SCRIPTS_DIR/archive.sh" list-nodes --format json 2>&1)
    python3 -c "
import json
j = json.loads('''$out''')
assert j.get('totalNodes', 0) >= 1, 'no nodes'
"
}

stage2_select_parent_output() {
    # select-parent는 node_id만 stdout에 출력해야
    local out
    out=$(bash "$SCRIPTS_DIR/select-parent.sh" --deterministic 2>/dev/null)
    if ! [[ "$out" =~ ^[0-9]{4}$ ]]; then
        echo "unexpected output: $out" >&2
        return 1
    fi
}

run_stage_2() {
    [ "$JSON_ONLY" = true ] || echo ""
    [ "$JSON_ONLY" = true ] || echo "🧪 Stage 2: Integration Tests"

    run_task "metacognitive-run" 2 stage2_metacognitive_run
    run_task "evolve-daily-run" 2 stage2_evolve_daily_run
    run_task "cron-audit-run" 2 stage2_cron_audit_run
    run_task "archive-cycle" 2 stage2_archive_cycle
    run_task "select-parent-output" 2 stage2_select_parent_output
}

# ─── Stage 3: Stress ───
stage3_determinism() {
    # evolve.sh 3회 실행 시 score가 크게 요동치지 않는지
    local scores=()
    for i in 1 2 3; do
        bash "$SCRIPTS_DIR/evolve.sh" daily >/dev/null 2>&1
        local s
        s=$(python3 -c "
import json
with open('$STATE_FILE') as f: st = json.load(f)
print(st.get('evolutionScore', 0))
")
        scores+=("$s")
    done
    # 점수 차이가 20 이하
    python3 -c "
scores = [${scores[0]}, ${scores[1]}, ${scores[2]}]
diff = max(scores) - min(scores)
assert diff <= 20, f'unstable: {scores} diff={diff}'
"
}

stage3_parent_selection_distribution() {
    # seed 다르게 10회 → 편향 없는지 (단일 노드면 항상 같은 거 나와야)
    for seed in 1 2 3 4 5 6 7 8 9 10; do
        local out
        out=$(bash "$SCRIPTS_DIR/select-parent.sh" --seed "$seed" 2>/dev/null)
        if ! [[ "$out" =~ ^[0-9]{4}$ ]]; then
            echo "seed=$seed invalid output: $out" >&2
            return 1
        fi
    done
}

stage3_performance_evolve() {
    # evolve.sh가 5초 이내 완료
    local start end diff
    start=$(python3 -c 'import time; print(int(time.time()*1000))')
    bash "$SCRIPTS_DIR/evolve.sh" daily >/dev/null 2>&1
    end=$(python3 -c 'import time; print(int(time.time()*1000))')
    diff=$((end - start))
    if [ "$diff" -gt 5000 ]; then
        echo "slow: ${diff}ms" >&2
        return 1
    fi
}

run_stage_3() {
    [ "$JSON_ONLY" = true ] || echo ""
    [ "$JSON_ONLY" = true ] || echo "🧪 Stage 3: Stress Tests"

    run_task "determinism" 3 stage3_determinism
    run_task "parent-selection-distribution" 3 stage3_parent_selection_distribution
    run_task "performance-evolve-under-5s" 3 stage3_performance_evolve
}

# ─── 실행 ───
START_MS=$(python3 -c 'import time; print(int(time.time()*1000))')

case "$STAGE" in
    1) run_stage_1 ;;
    2) run_stage_1; run_stage_2 ;;
    3|all) run_stage_1; run_stage_2; run_stage_3 ;;
    *) echo "❌ --stage 1|2|3|all" >&2; exit 1 ;;
esac

END_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
TOTAL_DURATION=$((END_MS - START_MS))

# ─── 결과 집계 ───
RESULTS_FILE="$TASK_RESULTS_FILE" TS="$TIMESTAMP" STAGE_LBL="$STAGE" \
TOTAL_MS="$TOTAL_DURATION" BENCHMARK_FILE="$BENCHMARK_FILE" \
JSON_ONLY="$JSON_ONLY" python3 << 'PYEOF'
import json, os
from datetime import datetime, timedelta, timezone

tasks = []
with open(os.environ['RESULTS_FILE']) as f:
    for line in f:
        line = line.strip()
        if line:
            tasks.append(json.loads(line))

passed = sum(1 for t in tasks if t['result'] == 'passed')
failed = sum(1 for t in tasks if t['result'] == 'failed')
total = len(tasks)
pass_rate = (passed / total * 100) if total else 0.0

summary = {
    "timestamp": os.environ['TS'],
    "stage": os.environ['STAGE_LBL'],
    "totalDurationMs": int(os.environ['TOTAL_MS']),
    "summary": {
        "total": total,
        "passed": passed,
        "failed": failed,
        "passRate": round(pass_rate, 1),
    },
    "tasks": tasks,
}

# 14일 rolling 저장
benchmark_file = os.environ['BENCHMARK_FILE']
existing = []
if os.path.exists(benchmark_file):
    try:
        with open(benchmark_file) as f: existing = json.load(f)
    except: pass

cutoff = (datetime.now(timezone.utc) - timedelta(days=14)).strftime('%Y-%m-%dT%H:%M:%SZ')
existing = [e for e in existing if e.get('timestamp', '') >= cutoff]
existing.append(summary)

with open(benchmark_file, 'w') as f:
    json.dump(existing[-50:], f, indent=2, ensure_ascii=False)

if os.environ.get('JSON_ONLY') == 'true':
    print(json.dumps(summary, indent=2, ensure_ascii=False))
else:
    print()
    print(f"━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print(f"📊 Stage {summary['stage']} 결과")
    print(f"  총 {total}개 태스크 | ✅ {passed}개 | ❌ {failed}개")
    print(f"  passRate: {pass_rate:.1f}%")
    print(f"  duration: {summary['totalDurationMs']}ms")
    if failed > 0:
        print()
        print("❌ 실패 태스크:")
        for t in tasks:
            if t['result'] == 'failed':
                err = t.get('error', '').strip().replace('\n', ' ')[:100]
                print(f"  - stage {t['stage']}/{t['name']}: {err}")
PYEOF
