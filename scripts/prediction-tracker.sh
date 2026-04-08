#!/bin/bash
# prediction-tracker.sh — 예측 정확도 검증
# 실행: prediction-tracker.sh
# 매주 heartbeat에서 실행 권장

set -euo pipefail

MEMORY_FILE="$HOME/Projects/openclaw/MEMORY.md"
TODAY=$(date '+%Y-%m-%d')

echo "🔮 예측 정확도 추적 — $TODAY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

python3 -c "
import re

with open('$MEMORY_FILE') as f:
    content = f.read()

# Predictions 섹션 파싱
pred_section = content.split('## 🔮 Predictions')[1].split('---')[0] if '## 🔮 Predictions' in content else ''

predictions = []
for line in pred_section.split('\n'):
    line = line.strip()
    if line.startswith('- ['):
        status = '❌' if '[❌]' in line else ('✅' if '[✅]' in line else '⏳')
        # Remove status markers
        text = re.sub(r'\[.\]\s*', '', line).strip()
        if text:
            predictions.append({'status': status, 'text': text})

if not predictions:
    print('예측이 없습니다.')
    exit(0)

# 통계
resolved = [p for p in predictions if p['status'] in ('✅', '❌')]
correct = [p for p in resolved if p['status'] == '✅']
pending = [p for p in predictions if p['status'] == '⏳']

accuracy = len(correct) / len(resolved) * 100 if resolved else 0

print(f'총 예측: {len(predictions)}개')
print(f'해결됨: {len(resolved)}개 (✅ {len(correct)} / ❌ {len(resolved)-len(correct)})')
print(f'진행 중: {len(pending)}개')
print(f'정확도: {accuracy:.0f}%')
print()

if pending:
    print('⏳ 해결 대기 중:')
    for p in pending:
        print(f'  • {p[\"text\"]}')

if resolved:
    print()
    print('📋 해결된 예측:')
    for p in resolved:
        print(f'  {p[\"status\"]} {p[\"text\"]}')
" 2>&1
