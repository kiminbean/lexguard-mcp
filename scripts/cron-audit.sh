#!/bin/bash
# cron-audit.sh — 크론잡 성과 추적 및 최적화 제안
# 실행: cron-audit.sh
# 출력: 각 크론잡의 가치 평가

set -euo pipefail

AUDIT_FILE="$HOME/Projects/openclaw/memory/cron-audit.json"
TODAY=$(date '+%Y-%m-%d')

echo "📊 크론잡 성과 감사 — $TODAY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 크론잡 목록 가져오기 (JSON 아님, 텍스트 출력 파싱)
JOBS_RAW=$(openclaw cron list 2>/dev/null || echo '')

# 텍스트 출력을 JSON으로 파싱
echo "$JOBS_RAW" | python3 -c "
import sys, json, re

lines = sys.stdin.read()

# 테이블 헤더에서 필드 추출
# openclaw cron list 출력 형식: ID NAME SCHEDULE ... STATUS TARGET ...
jobs = []
current_job = {}
for line in lines.split('\n'):
    line = line.strip()
    if not line or line.startswith('─') or line.startswith('Total'):
        continue
    
    # 탭으로 구분된 라인 파싱
    parts = line.split()
    parts = [p for p in parts if p]
    
    if len(parts) >= 2:
        if current_job and 'name' in current_job:
            jobs.append(current_job)
        current_job = {
            'name': parts[1] if len(parts) > 1 else 'Unknown',
            'enabled': True,
            'consecutiveErrors': 0,
            'lastRunStatus': 'ok' if 'ok' in line else 'error',
            'lastDurationMs': 0,
            'lastDelivered': False
        }
        
        # 에러 횟수 추출
        err_match = re.search(r'(\d+)\s*error', line)
        if err_match:
            current_job['consecutiveErrors'] = int(err_match.group(1))
        
        # duration 추출
        dur_match = re.search(r'(\d+)\s*ms\b', line)
        if dur_match:
            current_job['lastDurationMs'] = int(dur_match.group(1)) * 1000

if current_job and 'name' in current_job:
    jobs.append(current_job)

results = []
for job in jobs:
    name = job.get('name', 'Unknown')
    enabled = job.get('enabled', True)
    consec_errors = job.get('consecutiveErrors', 0)
    last_status = job.get('lastRunStatus', 'unknown')
    last_duration = job.get('lastDurationMs', 0)
    delivered = job.get('lastDelivered', False)
    
    # 가치 평가
    if not enabled:
        value = 'DISABLED'
    elif consec_errors >= 3:
        value = '🔴 문제'
    elif consec_errors >= 1:
        value = '🟡 주의'
    elif last_status == 'ok' and delivered:
        value = '🟢 활성'
    elif last_status == 'ok':
        value = '⚪ 자동'
    else:
        value = '❓ 미확인'
    
    results.append({
        'name': name,
        'value': value,
        'enabled': enabled,
        'errors': consec_errors,
        'duration_s': round(last_duration / 1000, 1),
        'delivered': delivered
    })

# 출력
active = [r for r in results if r['value'] not in ('DISABLED',)]
problems = [r for r in results if '🔴' in r['value'] or '🟡' in r['value']]

print(f'총 {len(results)}개 크론잡 (활성: {len(active)}, 문제: {len(problems)})')
print()

if problems:
    print('⚠️ 주의 필요:')
    for r in problems:
        print(f\"  {r['value']} {r['name']} (에러: {r['errors']}회, 소요: {r['duration_s']}s)\")
    print()

print('📋 전체 현황:')
for r in sorted(results, key=lambda x: x['value']):
    status = '' if r['enabled'] else ' [비활성]'
    delivered_mark = ' 📤' if r['delivered'] else ''
    print(f\"  {r['value']} {r['name']} ({r['duration_s']}s){status}{delivered_mark}\")

# JSON으로도 저장
import os
audit = []
if os.path.exists('$AUDIT_FILE'):
    try:
        with open('$AUDIT_FILE') as f:
            audit = json.load(f)
    except: pass

audit.append({
    'date': '$TODAY',
    'total': len(results),
    'active': len(active),
    'problems': len(problems),
    'details': results
})

# 최근 30일만 유지
audit = audit[-30:]

with open('$AUDIT_FILE', 'w') as f:
    json.dump(audit, f, indent=2, ensure_ascii=False)
" 2>&1
