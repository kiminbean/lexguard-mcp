#!/bin/bash
# hyperagents-restore.sh — HyperAgents 루프 복구
# 업데이트 후 HEARTBEAT.md가 초기화되었을 때 자동 복원
# 사용: hyperagents-restore.sh

set -euo pipefail

WORKSPACE="$HOME/Projects/openclaw"
HEARTBEAT="$WORKSPACE/HEARTBEAT.md"
SCRIPTS="$WORKSPACE/scripts"

echo "🧠 HyperAgents 복구 검사..."
RESTORED=0

# ─── 1. 스크립트 존재 확인 ───
for script in evolve.sh metacognitive.sh self-modify.sh auto-skill.sh cron-audit.sh prediction-tracker.sh settings-guard.sh; do
    if [ ! -f "$SCRIPTS/$script" ]; then
        echo "  ❌ $script 없음 — 복구 불가 (수동 복원 필요)"
    else
        echo "  ✅ $script"
    fi
done

# ─── 2. HEARTBEAT.md 무결성 확인 ───
if [ ! -f "$HEARTBEAT" ]; then
    echo "  ❌ HEARTBEAT.md 없음 — 새로 생성"
    RESTORED=1
fi

# HyperAgents 키워드가 HEARTBEAT에 있는지 확인
if ! grep -q "metacognitive" "$HEARTBEAT" 2>/dev/null; then
    echo "  ⚠️ HEARTBEAT.md에 metacognitive 누락 — 복원 필요"
    RESTORED=1
fi

if ! grep -q "self-modify" "$HEARTBEAT" 2>/dev/null; then
    echo "  ⚠️ HEARTBEAT.md에 self-modify 누락 — 복원 필요"
    RESTORED=1
fi

if ! grep -q "evolve.sh daily" "$HEARTBEAT" 2>/dev/null; then
    echo "  ⚠️ HEARTBEAT.md에 evolve.sh daily 누락 — 복원 필요"
    RESTORED=1
fi

# ─── 3. HEARTBEAT 복원 ───
if [ "$RESTORED" -eq 1 ]; then
    echo ""
    echo "  🔧 HEARTBEAT.md 복원 중..."
    
    # 기존 내용 백업
    if [ -f "$HEARTBEAT" ]; then
        cp "$HEARTBEAT" "$HEARTBEAT.bak.$(date '+%Y%m%d_%H%M%S')"
    fi

    # 누락된 섹션만 추가 (기존 내용 보존)
    if ! grep -q "metacognitive" "$HEARTBEAT" 2>/dev/null; then
        # 일 1회 섹션 찾아서 추가
        if grep -q "evolve.sh daily" "$HEARTBEAT" 2>/dev/null; then
            sed -i '' 's|evolve.sh daily|evolve.sh daily\n- `scripts/metacognitive.sh` 실행 — 자체 코드 분석, 성능 트렌드, 개선 제안\n- 고우선순위 제안 있으면 `scripts/metacognitive.sh --apply` → `scripts/self-modify.sh` 실행 (자기수정 루프)|' "$HEARTBEAT"
            echo "    ✅ metacognitive + self-modify 통합 복원"
        else
            # 섹션 자체가 없으면 추가
            cat >> "$HEARTBEAT" << 'HBEOF'

## 📍 일 1회 (매일 첫 heartbeat)
- `scripts/evolve.sh daily` 실행 — 실패/성공 패턴 분석, 사용자 모델, 메모리 최적화, 진화 점수
- `scripts/metacognitive.sh` 실행 — 자체 코드 분석, 성능 트렌드, 개선 제안
- 고우선순위 제안 있으면 `scripts/metacognitive.sh --apply` → `scripts/self-modify.sh` 실행 (자기수정 루프)
HBEOF
            echo "    ✅ 일 1회 섹션 신규 생성"
        fi
    fi

    if ! grep -q "evolve.sh weekly" "$HEARTBEAT" 2>/dev/null; then
        cat >> "$HEARTBEAT" << 'HBEOF'

## 🧠 주 1회 (일요일)
- `scripts/evolve.sh weekly` 실행 — 전체 진화 엔진 (스킬 생태계 분석 포함)
- scripts/auto-skill.sh로 반복 패턴 기반 스킬 자동 생성/개선
- scripts/cron-audit.sh로 크론잡 성과 감사
- MEMORY.md 정기 검토 및 갱신
HBEOF
        echo "    ✅ 주 1회 섹션 복원"
    fi

    echo "  ✅ HEARTBEAT.md 복원 완료"
fi

# ─── 4. memory 파일 확인 ───
mkdir -p "$WORKSPACE/memory"
for memfile in failure-patterns.md learning-state.json evolution-log.md metacognitive-log.md; do
    if [ ! -f "$WORKSPACE/memory/$memfile" ]; then
        case "$memfile" in
            failure-patterns.md)
                echo "# 실패 패턴 DB\n\n_에이전트가 겪은 오류와 교훈_\n\n---\n\n### 반복 주의사항\n\n1. **x**\n\n---" > "$WORKSPACE/memory/$memfile"
                ;;
            learning-state.json)
                echo '{"version": 1, "evolutionScore": 0}' > "$WORKSPACE/memory/$memfile"
                ;;
            evolution-log.md)
                echo "# 진화 로그\n\n---" > "$WORKSPACE/memory/$memfile"
                ;;
            metacognitive-log.md)
                echo "# 메타인지 로그\n\n---" > "$WORKSPACE/memory/$memfile"
                ;;
        esac
        echo "  🆕 memory/$memfile 생성"
    fi
done

# ─── 5. AGENTS.md HyperAgents 섹션 확인 ───
if ! grep -q "HyperAgents" "$WORKSPACE/AGENTS.md" 2>/dev/null; then
    echo "  ⚠️ AGENTS.md에 HyperAgents 섹션 누락 — 수동 복원 필요"
fi

echo ""
echo "✅ HyperAgents 복구 검사 완료"
