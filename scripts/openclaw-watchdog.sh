#!/bin/bash
# openclaw-watchdog.sh - Gateway 및 Telegram 상태 점검 스크립트

set -euo pipefail

TODAY=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE="$HOME/Projects/openclaw/memory/watchdog-$TODAY.log"

echo "🔍 Gateway 및 Telegram 상태 점검 - $TODAY" | tee -a "$LOG_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$LOG_FILE"

# 1. Gateway 상태 확인
echo "📡 Gateway 상태 확인 중..." | tee -a "$LOG_FILE"
GATEWAY_STATUS=$(openclaw gateway status 2>&1)
if [[ $? -eq 0 ]]; then
    echo "✅ Gateway: 정상" | tee -a "$LOG_FILE"
    echo "$GATEWAY_STATUS" | grep -E "(Service:|Gateway:|Runtime:)" | tee -a "$LOG_FILE"
else
    echo "❌ Gateway: 오류" | tee -a "$LOG_FILE"
    echo "$GATEWAY_STATUS" | tee -a "$LOG_FILE"
fi

# 2. 크론잡 상태 확인
echo "" | tee -a "$LOG_FILE"
echo "⏰ 크론잡 상태 확인 중..." | tee -a "$LOG_FILE"
CRON_STATUS=$(openclaw cron list 2>&1)
if [[ $? -eq 0 ]]; then
    echo "✅ 크론잡: 정상" | tee -a "$LOG_FILE"
    # Gateway Watchdog 상세 확인
    echo "$CRON_STATUS" | grep -A5 "Gateway Watchdog" | tee -a "$LOG_FILE"
else
    echo "❌ 크론잡: 오류" | tee -a "$LOG_FILE"
    echo "$CRON_STATUS" | tee -a "$LOG_FILE"
fi

# 3. 노드(Telegram) 상태 확인
echo "" | tee -a "$LOG_FILE"
echo "📱 노드(Telegram) 상태 확인 중..." | tee -a "$LOG_FILE"
NODE_STATUS=$(openclaw nodes status 2>&1)
if [[ $? -eq 0 ]]; then
    echo "✅ 노드 시스템: 정상" | tee -a "$LOG_FILE"
    # 연결된 노드 수 확인
    CONNECTED_NODES=$(echo "$NODE_STATUS" | grep -o "Connected: [0-9]*" | awk -F: '{print $2}' || echo "0")
    PAIRED_NODES=$(echo "$NODE_STATUS" | grep -o "Paired: [0-9]*" | awk -F: '{print $2}' || echo "0")
    echo "연결된 노드: $CONNECTED_NODES, 페어링된 노드: $PAIRED_NODES" | tee -a "$LOG_FILE"
    
    # 노드별 상태 출력
    echo "$NODE_STATUS" | tail -n +2 | sed '$d' | tee -a "$LOG_FILE"
else
    echo "❌ 노드: 오류" | tee -a "$LOG_FILE"
    echo "$NODE_STATUS" | tee -a "$LOG_FILE"
fi

# 4. 시스템 리소스 확인
echo "" | tee -a "$LOG_FILE"
echo "💾 시스템 리소스 확인 중..." | tee -a "$LOG_FILE"
MEMORY_INFO=$(top -l 1 -n 0 | grep "PhysMem")
if [[ $? -eq 0 ]]; then
    echo "✅ 시스템 메모리: 정상" | tee -a "$LOG_FILE"
    echo "메모리 정보: $MEMORY_INFO" | tee -a "$LOG_FILE"
else
    echo "⚠️ 시스템 메모리: 확인 불가" | tee -a "$LOG_FILE"
fi

# 5. 최종 결과
echo "" | tee -a "$LOG_FILE"
echo "📊 점검 결과 요약 - $TODAY" | tee -a "$LOG_FILE"

# 상태 판별
ERROR_COUNT=0
if echo "$GATEWAY_STATUS" | grep -q "❌\|error\|오류"; then
    echo "❌ Gateway 오류 감지" | tee -a "$LOG_FILE"
    ((ERROR_COUNT++))
fi

if echo "$CRON_STATUS" | grep -q "❌\|error\|오류"; then
    echo "❌ 크론잡 오류 감지" | tee -a "$LOG_FILE"
    ((ERROR_COUNT++))
fi

if [[ $CONNECTED_NODES -eq 0 ]]; then
    echo "⚠️ 연결된 노드 없음" | tee -a "$LOG_FILE"
    ((ERROR_COUNT++))
fi

if [[ $ERROR_COUNT -eq 0 ]]; then
    echo "✅ 모든 서비스 정상" | tee -a "$LOG_FILE"
    exit 0
else
    echo "❌ 총 $ERROR_COUNT개 문제 감지" | tee -a "$LOG_FILE"
    exit 1
fi