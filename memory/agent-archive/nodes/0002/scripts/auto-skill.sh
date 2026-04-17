#!/bin/bash
# auto-skill.sh — 대화 패턴에서 자동으로 스킬 생성
# Usage: auto-skill.sh "작업 설명" "카테고리"
# 최대 50개 초과 시 사용 빈도가 가장 낮은 스킬 자동 삭제 후 생성

set -euo pipefail

TASK_DESC="${1:-}"
CATEGORY="${2:-general}"
SKILLS_DIR="$HOME/.openclaw/skills"
LEARNING_STATE="$HOME/Projects/openclaw/memory/learning-state.json"
MAX_SKILLS=50  # 자동 생성 스킬 최대 개수

if [ -z "$TASK_DESC" ]; then
    echo "Usage: auto-skill.sh \"작업 설명\" [카테고리]"
    exit 1
fi

# 스킬 개수 확인
CURRENT_COUNT=$(ls -1d "$SKILLS_DIR"/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ')

# 최대 개수 초과 시 사용 빈도가 가장 낮은 스킬 삭제
if [ "$CURRENT_COUNT" -ge "$MAX_SKILLS" ]; then
    echo "LIMIT: 스킬이 ${CURRENT_COUNT}개로 최대 ${MAX_SKILLS}개 초과"
    echo "  → 사용 빈도가 가장 낮은 스킬을 자동 삭제합니다..."
    
    # 사용 빈도가 가장 낮은 스킬 찾기 (마지막 수정 시간이 가장 오래된 것)
    OLDEST_SKILL=$(find "$SKILLS_DIR" -maxdepth 2 -name "SKILL.md" -type f -exec stat -f "%m %N" {} \; 2>/dev/null | sort -n | head -1 | sed 's/^[0-9]* //')
    
    if [ -n "$OLDEST_SKILL" ]; then
        OLDEST_DIR=$(dirname "$OLDEST_SKILL")
        OLDEST_NAME=$(basename "$OLDEST_DIR")
        
        # 보호된 스킬은 삭제하지 않음 (수동 생성 스킬)
        if grep -q "Auto-generated" "$OLDEST_SKILL" 2>/dev/null; then
            rm -rf "$OLDEST_DIR"
            echo "  🗑️ 삭제됨: $OLDEST_NAME (마지막 수정: $(stat -f '%Sm' -t '%Y-%m-%d' "$OLDEST_SKILL" 2>/dev/null || echo 'unknown'))"
            
            # 학습 상태에 삭제 기록
            if command -v python3 &>/dev/null && [ -f "$LEARNING_STATE" ]; then
                python3 -c "
import json
with open('$LEARNING_STATE') as f:
    state = json.load(f)
state['skillsCreated'] = state.get('skillsCreated', 0)
state['skillsEvicted'] = state.get('skillsEvicted', 0) + 1
state['lastEvicted'] = '$OLDEST_NAME'
with open('$LEARNING_STATE', 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
"
            fi
        else
            echo "  ⚠️ 가장 오래된 스킬($OLDEST_NAME)이 수동 생성 스킬입니다. 삭제하지 않습니다."
            # 수동 스킬은 건너뛰고 다음 자동 스킬 찾기
            OLDEST_SKILL=$(find "$SKILLS_DIR" -maxdepth 2 -name "SKILL.md" -type f -exec stat -f "%m %N" {} \; 2>/dev/null | sort -n | head -2 | tail -1 | sed 's/^[0-9]* //')
            if [ -n "$OLDEST_SKILL" ]; then
                OLDEST_DIR=$(dirname "$OLDEST_SKILL")
                OLDEST_NAME=$(basename "$OLDEST_DIR")
                if grep -q "Auto-generated" "$OLDEST_SKILL" 2>/dev/null; then
                    rm -rf "$OLDEST_DIR"
                    echo "  🗑️ 삭제됨: $OLDEST_NAME"
                else
                    echo "  ❌ 삭제 가능한 자동 스킬이 없습니다. 수동 정리가 필요합니다."
                    exit 1
                fi
            fi
        fi
    fi
fi

# 작업 설명에서 스킬 이름 생성 (소문자, 하이픈)
SKILL_NAME=$(echo "$TASK_DESC" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9가-힣]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-50)

if [ -z "$SKILL_NAME" ]; then
    SKILL_NAME="auto-skill-$(date +%s)"
fi

# 한국어 이름 생성 시 영어 prefix 추가
if echo "$SKILL_NAME" | grep -q '[가-힣]'; then
    SKILL_NAME="ko-$SKILL_NAME"
fi

SKILL_DIR="$SKILLS_DIR/$SKILL_NAME"

# 이미 존재하면 개선 모드
if [ -d "$SKILL_DIR" ]; then
    echo "EXISTS:$SKILL_NAME"
    echo "  → 스킬이 이미 존재합니다. 개선이 필요하면 SKILL.md를 업데이트하세요."
    echo "  경로: $SKILL_DIR/SKILL.md"
    
    # 학습 이력에 사용 기록 추가
    if grep -q "## 학습 이력" "$SKILL_DIR/SKILL.md" 2>/dev/null; then
        # 마지막 사용 날짜 업데이트
        sed -i '' "s/^## 학습 이력/## 학습 이력/" "$SKILL_DIR/SKILL.md"
        echo "- $(date '+%Y-%m-%d'): 재사용 감지" >> "$SKILL_DIR/SKILL.md"
    fi
    exit 0
fi

# 새 스킬 생성
mkdir -p "$SKILL_DIR"
mkdir -p "$SKILL_DIR/references"

cat > "$SKILL_DIR/SKILL.md" << SKILLEOF
---
name: $SKILL_NAME
description: |
  Auto-generated skill from task pattern.
  Task: $TASK_DESC
  Category: $CATEGORY
  Created: $(date '+%Y-%m-%d')
---

# $SKILL_NAME

> Auto-generated from task pattern. Improve as needed.

## 작업
$TASK_DESC

## 절차
<!-- 이 스킬을 사용할 때마다 개선하세요 -->

1. (자동 생성됨 — 실제 절차로 교체 필요)

## 주의사항
- 이 스킬은 자동 생성되었습니다
- 사용 후 절차를 구체화하세요
- 패턴이 반복되면 references/에 상세 가이드 추가

## 학습 이력
- $(date '+%Y-%m-%d'): 초기 생성
SKILLEOF

# 학습 상태 업데이트
if command -v python3 &>/dev/null && [ -f "$LEARNING_STATE" ]; then
    python3 -c "
import json
with open('$LEARNING_STATE') as f:
    state = json.load(f)
state['skillsCreated'] = state.get('skillsCreated', 0) + 1
state['lastLearningAt'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
patterns = state.get('patternsDetected', [])
patterns.append('$TASK_DESC')
state['patternsDetected'] = patterns[-20:]  # 최근 20개만 유지
with open('$LEARNING_STATE', 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
"
fi

echo "CREATED:$SKILL_NAME"
echo "  경로: $SKILL_DIR/SKILL.md"
echo "  다음 단계: SKILL.md의 절차를 실제 작업 내용으로 구체화하세요"
