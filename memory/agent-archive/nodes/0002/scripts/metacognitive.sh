#!/bin/bash
# metacognitive.sh — HyperAgents 메타인지 엔진 v4 (DGM-H 벤치마크 통합)
#
# 변경점 (v4, 2026-04-18):
# - benchmark-results.json 읽어서 metrics['benchmark'] = {passRate, latestFailures} 수집
# - 새 제안 규칙: benchmark.passRate < 80 → high/medium priority proposal
# - schemaVersion: 4
#
# 변경점 (v3 기준, 유지):
# - 자기참조 지표 제거: completionRate(이모지 카운트), userModelScore(키워드 체크) 삭제
# - 외부 효과 지표 도입: deliveryRate, errorRecoveryRate, proposalAttrition, externalSignal
# - --json 플래그 우선 사용 (openclaw cron list --json)
# - 제안 수명주기 관리 (14일 경과 pending → archived)
#
# 사용: metacognitive.sh

set -euo pipefail

WORKSPACE="$HOME/Projects/openclaw"
MEMORY="$WORKSPACE/memory"
STATE_FILE="$MEMORY/learning-state.json"
META_LOG="$MEMORY/metacognitive-log.md"
SCRIPTS_DIR="$WORKSPACE/scripts"
FAILURES_FILE="$MEMORY/failure-patterns.md"
PROPOSALS_DIR="$MEMORY/proposals"
PROPOSALS_ARCHIVE="$MEMORY/proposals/archive"

TODAY=$(date '+%Y-%m-%d')
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
PROPOSAL_TTL_DAYS=14

mkdir -p "$MEMORY" "$PROPOSALS_DIR" "$PROPOSALS_ARCHIVE"

if [ ! -f "$META_LOG" ]; then
    cat > "$META_LOG" << 'EOF'
# 메타인지 로그

_에이전트가 자신의 성능과 개선 방향을 평가한 기록_

---
EOF
fi

# ─── 1. 외부 효과 지표 수집 (v4) ───
collect_metrics() {
    echo "📊 외부 효과 지표 수집 (v4)..."

    python3 << PYEOF
import json, os, glob, re, subprocess, hashlib
from datetime import datetime, timedelta, timezone

state_file = "$STATE_FILE"
memory_dir = "$MEMORY"
scripts_dir = "$SCRIPTS_DIR"
today = "$TODAY"
timestamp = "$TIMESTAMP"

state = {}
if os.path.exists(state_file):
    with open(state_file) as f:
        state = json.load(f)

prev_metrics = state.get('metrics', {})
metrics = {}

# ─── 1.1. 크론잡 건강도 (--json 우선) ───
cron_jobs = []
try:
    r = subprocess.run(['openclaw', 'cron', 'list', '--json'],
                       capture_output=True, text=True, timeout=30)
    if r.returncode == 0:
        cron_data = json.loads(r.stdout)
        cron_jobs = cron_data.get('jobs', [])
except Exception as e:
    print(f"  ⚠️ cron list --json 실패: {e}")

total = len(cron_jobs)
active = sum(1 for j in cron_jobs if j.get('enabled', True))
erroring = sum(1 for j in cron_jobs if j.get('state', {}).get('consecutiveErrors', 0) > 0)
critical = sum(1 for j in cron_jobs if j.get('state', {}).get('consecutiveErrors', 0) >= 3)

# 성공률: lastRunStatus == 'ok'
executed = [j for j in cron_jobs if j.get('state', {}).get('lastRunStatus')]
success_rate = (sum(1 for j in executed if j.get('state', {}).get('lastRunStatus') == 'ok')
                / len(executed) * 100) if executed else 0

# ★ v3 핵심: 전달률 (delivered:true 비율)
delivered_count = sum(1 for j in executed if j.get('state', {}).get('lastDelivered') is True)
delivery_rate = (delivered_count / len(executed) * 100) if executed else 0

# 평균 실행시간
durs = [j.get('state', {}).get('lastDurationMs', 0) for j in cron_jobs
        if j.get('state', {}).get('lastDurationMs')]
avg_duration = sum(durs) / len(durs) if durs else 0

# 에러 회복률: 이전 실행 대비 consecutiveErrors 감소한 잡 비율
prev_err_snapshot = prev_metrics.get('cron', {}).get('errorSnapshot', {})
curr_err_snapshot = {j['id']: j.get('state', {}).get('consecutiveErrors', 0)
                     for j in cron_jobs if j.get('id')}
recovery_events = 0
regression_events = 0
for jid, prev_err in prev_err_snapshot.items():
    curr_err = curr_err_snapshot.get(jid, 0)
    if prev_err > 0 and curr_err < prev_err:
        recovery_events += 1
    elif curr_err > prev_err:
        regression_events += 1

metrics['cron'] = {
    'total': total,
    'active': active,
    'erroring': erroring,
    'critical': critical,
    'successRate': round(success_rate, 1),
    'deliveryRate': round(delivery_rate, 1),  # v3
    'avgDurationMs': round(avg_duration),
    'recoveryEvents': recovery_events,
    'regressionEvents': regression_events,
    'errorSnapshot': curr_err_snapshot,
}

print(f"  📡 크론: {total}개 (활성 {active}, 에러 {erroring}, 임계 {critical})")
print(f"     성공률 {success_rate:.0f}% | 전달률 {delivery_rate:.0f}%")
print(f"     복구 {recovery_events}건 / 퇴행 {regression_events}건")

if critical > 0:
    for j in cron_jobs:
        errs = j.get('state', {}).get('consecutiveErrors', 0)
        if errs >= 3:
            reason = j.get('state', {}).get('lastErrorReason', '?')
            print(f"     🔴 {j.get('name','?')}: {errs}회 ({reason})")

# ─── 1.2. 외부 신호 포착율 (failure-patterns.md 변화) ───
failures_file = "$FAILURES_FILE"
external_signal = {'newFailures7d': 0, 'lastFailureDate': None}
if os.path.exists(failures_file):
    with open(failures_file) as f:
        fc = f.read()
    # 날짜 헤더 추출: "### YYYY-MM-DD:"
    dates = re.findall(r'### (\d{4}-\d{2}-\d{2}):', fc)
    if dates:
        external_signal['lastFailureDate'] = max(dates)
        seven_ago = (datetime.now() - timedelta(days=7)).strftime('%Y-%m-%d')
        external_signal['newFailures7d'] = sum(1 for d in dates if d >= seven_ago)

metrics['externalSignal'] = external_signal
days_since = 'N/A'
if external_signal['lastFailureDate']:
    last_dt = datetime.strptime(external_signal['lastFailureDate'], '%Y-%m-%d')
    days_since = (datetime.now() - last_dt).days
print(f"  📋 외부신호: 최근7일 {external_signal['newFailures7d']}건, 마지막 {external_signal['lastFailureDate']} ({days_since}일 전)")

# ─── 1.3. 제안 수명주기 (proposal attrition) ───
proposals_dir = "$PROPOSALS_DIR"
archive_dir = "$PROPOSALS_ARCHIVE"
md_files = glob.glob(os.path.join(proposals_dir, '*.md'))

pending = 0
applied = 0
archived_now = 0
ttl_days = $PROPOSAL_TTL_DAYS

for path in md_files:
    try:
        with open(path) as f:
            content = f.read()
        status_match = re.search(r'^STATUS:\s*(\S+)', content, re.MULTILINE)
        date_match = re.search(r'^DATE:\s*(\d{4}-\d{2}-\d{2})', content, re.MULTILINE)
        status = status_match.group(1).lower() if status_match else 'pending'
        pdate = date_match.group(1) if date_match else today

        if status == 'applied':
            applied += 1
        elif status == 'pending':
            # TTL 체크
            try:
                pdt = datetime.strptime(pdate, '%Y-%m-%d')
                age_days = (datetime.now() - pdt).days
                if age_days >= ttl_days:
                    # 아카이브로 이동
                    archive_path = os.path.join(archive_dir, os.path.basename(path))
                    os.rename(path, archive_path)
                    # status를 expired로 마킹
                    with open(archive_path) as af: ac = af.read()
                    ac = re.sub(r'^STATUS:.*$', f'STATUS: expired-{today}', ac, flags=re.MULTILINE)
                    with open(archive_path, 'w') as af: af.write(ac)
                    archived_now += 1
                else:
                    pending += 1
            except ValueError:
                pending += 1
    except Exception:
        continue

total_proposals = pending + applied
attrition_rate = (applied / total_proposals * 100) if total_proposals > 0 else 0

metrics['proposals'] = {
    'pending': pending,
    'applied': applied,
    'archivedThisRun': archived_now,
    'attritionRate': round(attrition_rate, 1),
    'ttlDays': ttl_days,
}
print(f"  📁 제안: pending {pending} / applied {applied} / 이번 아카이브 {archived_now}")
print(f"     소진율 {attrition_rate:.0f}%")

# ─── 1.4. 스크립트 안정성 (잦은 수정 = 불안정) ───
tracked_scripts = ['evolve.sh', 'metacognitive.sh', 'self-modify.sh',
                   'cron-audit.sh', 'notify-hyperagent.sh']
prev_hashes = state.get('scriptHashes', {})
curr_hashes = {}
churn = 0
for s in tracked_scripts:
    path = os.path.join(scripts_dir, s)
    if os.path.exists(path):
        with open(path, 'rb') as f:
            h = hashlib.sha256(f.read()).hexdigest()[:12]
        curr_hashes[s] = {'hash': h, 'size': os.path.getsize(path)}
        if prev_hashes.get(s, {}).get('hash') != h and prev_hashes.get(s):
            churn += 1
metrics['stability'] = {'churnThisRun': churn, 'tracked': len(curr_hashes)}
state['scriptHashes'] = curr_hashes
print(f"  🔧 코어 스크립트: {len(curr_hashes)}개 추적, 변경 {churn}건")

# ─── 1.5. 메모리 크기 (참고용) ───
memory_md = os.path.join("$WORKSPACE", "MEMORY.md")
mem_size = os.path.getsize(memory_md) if os.path.exists(memory_md) else 0
metrics['memory'] = {
    'sizeBytes': mem_size,
    'sizeKB': round(mem_size / 1024, 1),
}

# ─── 1.6. 벤치마크 품질 (v4 신설) ───
benchmark_file = os.path.join(memory_dir, 'benchmark-results.json')
benchmark_info = {'passRate': None, 'lastRun': None, 'totalRuns14d': 0, 'latestFailures': []}
if os.path.exists(benchmark_file):
    try:
        with open(benchmark_file) as bf:
            bench_data = json.load(bf)
        if bench_data:
            latest = bench_data[-1]
            benchmark_info['passRate'] = latest.get('summary', {}).get('passRate', 0)
            benchmark_info['lastRun'] = latest.get('timestamp')
            benchmark_info['totalRuns14d'] = len(bench_data)
            failed_tasks = [t for t in latest.get('tasks', []) if t.get('result') == 'failed']
            benchmark_info['latestFailures'] = [t.get('name', '?') for t in failed_tasks][:5]
    except Exception as e:
        print(f"  ⚠️ benchmark 읽기 실패: {e}")

metrics['benchmark'] = benchmark_info
if benchmark_info['passRate'] is not None:
    fail_hint = f" (실패: {', '.join(benchmark_info['latestFailures'][:3])})" if benchmark_info['latestFailures'] else ""
    print(f"  🧪 벤치마크: passRate {benchmark_info['passRate']:.0f}% (14일 {benchmark_info['totalRuns14d']}회){fail_hint}")
else:
    print(f"  🧪 벤치마크: 미실행")

# ─── 1.7. archive 아카이브 상태 (v4 신설) ───
archive_index = os.path.join(memory_dir, 'agent-archive', 'index.json')
archive_info = {'totalNodes': 0, 'activeNodeId': state.get('activeNodeId', ''), 'latestScore': None}
if os.path.exists(archive_index):
    try:
        with open(archive_index) as af:
            idx = json.load(af)
        nodes = idx.get('nodes', [])
        archive_info['totalNodes'] = len(nodes)
        if nodes:
            archive_info['latestScore'] = nodes[-1].get('score', 0)
    except Exception:
        pass
metrics['archive'] = archive_info
if archive_info['totalNodes'] > 0:
    print(f"  🧬 아카이브: {archive_info['totalNodes']}노드 (active: {archive_info['activeNodeId'] or '-'}, 최신 {archive_info['latestScore']}점)")

state['metrics'] = metrics
state['lastMetaAnalysis'] = timestamp
state['metaAnalysisCount'] = state.get('metaAnalysisCount', 0) + 1
state['schemaVersion'] = 4

with open(state_file, 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
PYEOF
}

# ─── 2. 제안 생성 (v4 지표 기반) ───
generate_proposals() {
    echo ""
    echo "💡 제안 생성 (v4)..."

    python3 << PYEOF
import json, os

state_file = "$STATE_FILE"
meta_log = "$META_LOG"
proposals_dir = "$PROPOSALS_DIR"
today = "$TODAY"
timestamp = "$TIMESTAMP"

with open(state_file) as f:
    state = json.load(f)

m = state.get('metrics', {})
proposals = []

cron = m.get('cron', {})
prop = m.get('proposals', {})
ext = m.get('externalSignal', {})

# ─── 규칙 1: 전달률 저조 (v3 최우선) ───
delivery_rate = cron.get('deliveryRate', 100)
if delivery_rate < 50 and cron.get('total', 0) >= 3:
    proposals.append({
        'id': 'delivery-rate-low',
        'priority': 'high',
        'metric': f'전달률 {delivery_rate:.0f}%',
        'description': f'실행된 크론 중 {delivery_rate:.0f}%만 사용자에게 전달됨. 산출물 누수.',
        'action': '각 크론 payload에 Telegram 전달 단계 명시, notify-hyperagent.sh 호출',
        'evidence': f'deliveryRate = {delivery_rate}%',
        'autoDiffable': False,
    })

# ─── 규칙 2: 임계 에러 ───
critical = cron.get('critical', 0)
if critical >= 2:
    proposals.append({
        'id': 'cron-critical-errors',
        'priority': 'high',
        'metric': f'임계 에러 {critical}개',
        'description': f'{critical}개 크론이 3회 이상 연속 실패. 자동 비활성화 고려.',
        'action': 'consecutiveErrors >= 5 크론은 openclaw cron disable 수행',
        'evidence': 'consecutiveErrors >= 3',
        'autoDiffable': False,
    })
elif critical == 1:
    proposals.append({
        'id': 'cron-warning',
        'priority': 'medium',
        'metric': f'에러 1개',
        'description': '1개 크론 연속 에러',
        'action': '원인 확인 + 다음 실행 관찰',
        'evidence': 'consecutiveErrors >= 3',
        'autoDiffable': False,
    })

# ─── 규칙 3: 성공률 저하 ───
sr = cron.get('successRate', 100)
if sr < 70 and cron.get('total', 0) >= 3:
    proposals.append({
        'id': 'cron-success-rate-low',
        'priority': 'high',
        'metric': f'성공률 {sr:.0f}%',
        'description': f'크론 성공률 {sr:.0f}%',
        'action': 'timeout 증가 또는 payload 단순화',
        'evidence': f'successRate = {sr}%',
        'autoDiffable': False,
    })

# ─── 규칙 4: 실행시간 과다 ───
ad = cron.get('avgDurationMs', 0)
if ad > 120000:
    proposals.append({
        'id': 'cron-slow',
        'priority': 'medium',
        'metric': f'{ad/1000:.0f}초',
        'description': f'평균 실행 {ad/1000:.0f}초',
        'action': 'lightContext 활용, payload 단순화',
        'evidence': f'avgDurationMs = {ad}',
        'autoDiffable': False,
    })

# ─── 규칙 5: 외부신호 고갈 (정체 경고) ───
days_since = None
if ext.get('lastFailureDate'):
    from datetime import datetime
    last = datetime.strptime(ext['lastFailureDate'], '%Y-%m-%d')
    days_since = (datetime.now() - last).days

if days_since is not None and days_since >= 14:
    proposals.append({
        'id': 'external-signal-stale',
        'priority': 'medium',
        'metric': f'마지막 실패 기록 {days_since}일 전',
        'description': f'failure-patterns.md가 {days_since}일 정체. 입력 데이터 고갈 또는 실패 기록 습관 상실.',
        'action': '실패 발생 시 failure-patterns.md에 기록 훅 추가. heartbeat에 알림',
        'evidence': f'lastFailureDate = {ext.get("lastFailureDate")}',
        'autoDiffable': False,
    })

# ─── 규칙 6: 제안 소진율 낮음 ───
attrition = prop.get('attritionRate', 100)
pending = prop.get('pending', 0)
applied = prop.get('applied', 0)
if pending >= 3 and attrition < 30:
    proposals.append({
        'id': 'proposal-stagnation',
        'priority': 'medium',
        'metric': f'소진율 {attrition:.0f}%, 대기 {pending}개',
        'description': '제안이 쌓이지만 적용되지 않음. 루프 폐쇄 실패.',
        'action': 'self-modify.sh --auto 모드로 템플릿 기반 자동 적용 확대',
        'evidence': f'pending={pending}, applied={applied}',
        'autoDiffable': False,
    })

# ─── 규칙 7: 회복 없는 퇴행 ───
recov = cron.get('recoveryEvents', 0)
regr = cron.get('regressionEvents', 0)
if regr >= 2 and recov == 0:
    proposals.append({
        'id': 'error-only-regression',
        'priority': 'high',
        'metric': f'복구 0 / 퇴행 {regr}',
        'description': f'에러 회복 없이 퇴행만 {regr}건. 시스템이 악화 중.',
        'action': '에러 크론 긴급 점검 + heartbeat 진단',
        'evidence': f'recovery=0, regression={regr}',
        'autoDiffable': False,
    })

# ─── 규칙 8: 벤치마크 passRate 저조 (v4 신설) ───
bench = m.get('benchmark', {})
pr = bench.get('passRate')
if pr is not None and pr < 80:
    failures = bench.get('latestFailures', [])
    failure_summary = ', '.join(failures[:3]) + ('...' if len(failures) > 3 else '') if failures else 'unknown'
    proposals.append({
        'id': 'benchmark-failing',
        'priority': 'high' if pr < 60 else 'medium',
        'metric': f'benchmark passRate {pr:.0f}%',
        'description': f'benchmark.sh passRate {pr:.0f}% — 운영 벤치마크 저하. 실패 태스크: {failure_summary}',
        'action': 'propose-mutation.sh --target <실패스크립트>로 LLM 수정안 생성 후 self-modify.sh --auto 적용',
        'evidence': f'benchmark.passRate = {pr}, failures: {failure_summary}',
        'autoDiffable': False,
    })

# ─── 규칙 9: archive 정체 (v4 신설) ───
arch = m.get('archive', {})
total_nodes = arch.get('totalNodes', 0)
if total_nodes >= 10 and prop.get('applied', 0) < 2:
    proposals.append({
        'id': 'archive-stagnation',
        'priority': 'low',
        'metric': f'archive {total_nodes}노드 / applied {prop.get("applied",0)}',
        'description': f'archive에 {total_nodes}개 노드가 쌓였지만 실제 자기수정 적용이 저조.',
        'action': 'select-parent.sh로 최적 부모 선택 → propose-mutation.sh로 변형 생성 → 검증 후 적용 파이프라인 가동',
        'evidence': f'archive.totalNodes={total_nodes}, proposals.applied={prop.get("applied",0)}',
        'autoDiffable': False,
    })

# ─── 출력 및 저장 ───
if proposals:
    proposals.sort(key=lambda x: {'high': 0, 'medium': 1, 'low': 2}.get(x['priority'], 3))
    print(f"  📋 {len(proposals)}개 제안:")
    for p in proposals:
        icon = {'high': '🔴', 'medium': '🟡', 'low': '🟢'}.get(p['priority'], '⚪')
        print(f"    {icon} [{p['priority']}] {p['id']}")
        print(f"       지표: {p['metric']}")
        print(f"       제안: {p['action']}")
else:
    print(f"  ✅ 개선 제안 없음 — 모든 지표 양호")

state['metacognitiveProposals'] = proposals
state['lastProposalGeneration'] = timestamp

with open(state_file, 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)

# 제안 파일 생성
target_map = {
    'delivery-rate-low': 'notify-hyperagent.sh',
    'cron-critical-errors': 'cron-audit.sh',
    'cron-warning': 'cron-audit.sh',
    'cron-success-rate-low': 'cron-audit.sh',
    'cron-slow': 'cron-audit.sh',
    'external-signal-stale': 'evolve.sh',
    'proposal-stagnation': 'self-modify.sh',
    'error-only-regression': 'cron-audit.sh',
    'benchmark-failing': 'self-modify.sh',
    'archive-stagnation': 'self-modify.sh',
}

written = 0
for p in proposals:
    pid = p.get('id', 'unknown')
    path = os.path.join(proposals_dir, f"{pid}.md")
    if os.path.exists(path):
        with open(path) as pf:
            if f"DATE: {today}" in pf.read():
                continue
    target = target_map.get(pid, 'evolve.sh')
    with open(path, 'w') as pf:
        pf.write(f"TARGET: {target}\n")
        pf.write(f"PRIORITY: {p.get('priority', 'low')}\n")
        pf.write(f"METRIC: {p.get('metric', 'N/A')}\n")
        pf.write(f"DESCRIPTION: {p.get('description', '')}\n")
        pf.write(f"ACTION: {p.get('action', '')}\n")
        pf.write(f"EVIDENCE: {p.get('evidence', '')}\n")
        pf.write(f"DATE: {today}\n")
        pf.write(f"STATUS: pending\n")
        pf.write(f"AUTO_DIFFABLE: {str(p.get('autoDiffable', False)).lower()}\n")
    written += 1

if written > 0:
    print(f"  📁 {written}개 제안 파일 생성")

# 메타 로그
if proposals:
    hc = len([p for p in proposals if p['priority'] == 'high'])
    mc = len([p for p in proposals if p['priority'] == 'medium'])
    lc = len([p for p in proposals if p['priority'] == 'low'])
    with open(meta_log, 'a') as f:
        f.write(f"\n## [{today}] 메타인지 v4\n")
        bench_hint = ""
        bench_pr = m.get('benchmark', {}).get('passRate')
        if bench_pr is not None:
            bench_hint = f" · 벤치 {bench_pr:.0f}%"
        f.write(f"- **지표**: 성공률 {cron.get('successRate',0):.0f}% · 전달률 {cron.get('deliveryRate',0):.0f}% · 임계 {cron.get('critical',0)}개{bench_hint}\n")
        f.write(f"- **제안**: 🔴{hc} 🟡{mc} 🟢{lc}\n")
        for p in proposals:
            f.write(f"  - [{p['priority']}] {p['id']}: {p['action']}\n")
PYEOF
}

echo "🧠 메타인지 엔진 v4 ($TODAY)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
collect_metrics
generate_proposals
echo ""
echo "✅ 메타인지 v4 완료"
