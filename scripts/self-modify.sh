#!/bin/bash
# self-modify.sh — HyperAgents 기반 자기수정 제안 생성기
# 
# 변경점 (v2 — HyperAgents 적용):
# - bash 하드코딩 수정 → 제안(diff)만 생성, 실제 적용은 AI 세션에서
# - Meta Agent 역할: 전체 코드 분석 후 구체적 수정안 생성
# - 버전 관리 + 롤백 안전망 유지
#
# 사용: self-modify.sh [--dry-run] [--apply <proposal-file>]

set -euo pipefail

WORKSPACE="$HOME/Projects/openclaw"
MEMORY="$WORKSPACE/memory"
SCRIPTS_DIR="$WORKSPACE/scripts"
BACKUP_DIR="$WORKSPACE/scripts/backup/self-modify"
PROPOSALS_DIR="$WORKSPACE/memory/proposals"
STATE_FILE="$MEMORY/learning-state.json"
META_LOG="$MEMORY/metacognitive-log.md"

TODAY=$(date '+%Y-%m-%d')
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# 수정 허용 대상
ALLOWED_TARGETS=(
    "evolve.sh"
    "metacognitive.sh"
    "auto-skill.sh"
    "cron-audit.sh"
    "prediction-tracker.sh"
    "self-modify.sh"
)

mkdir -p "$BACKUP_DIR" "$PROPOSALS_DIR"

# ─── 1. 백업 ───
backup_script() {
    local script="$1"
    local script_path="$SCRIPTS_DIR/$script"
    
    if [ ! -f "$script_path" ]; then
        echo "  ❌ $script 없음 — 스킵"
        return 1
    fi

    local backup_path="$BACKUP_DIR/${script}.$(date '+%Y%m%d_%H%M%S').bak"
    cp "$script_path" "$backup_path"
    echo "  💾 백업: $backup_path"
    return 0
}

# ─── 2. 실제 적용 (AI 세션에서만 호출) ───
apply_proposal() {
    local proposal_file="$1"
    
    if [ ! -f "$proposal_file" ]; then
        echo "  ❌ 제안 파일 없음: $proposal_file"
        return 1
    fi
    
    # 제안 파일에서 대상 스크립트 추출
    local target=$(grep '^TARGET:' "$proposal_file" | cut -d' ' -f2)
    
    if [[ ! " ${ALLOWED_TARGETS[@]} " =~ " ${target} " ]]; then
        echo "  🚫 $target — 수정 허용 대상 아님"
        return 1
    fi
    
    local script_path="$SCRIPTS_DIR/$target"
    
    # 백업
    backup_script "$target" || return 1
    
    # diff 적용
    local diff_file="${proposal_file%.md}.diff"
    if [ -f "$diff_file" ]; then
        patch -p1 -d "$SCRIPTS_DIR" < "$diff_file" 2>&1
        if [ $? -ne 0 ]; then
            echo "  ❌ 패치 실패 — 롤백"
            local latest_backup=$(ls -t "$BACKUP_DIR/${target}."*.bak 2>/dev/null | head -1)
            if [ -n "$latest_backup" ]; then
                cp "$latest_backup" "$script_path"
                echo "  ✅ 롤백 완료"
            fi
            return 1
        fi
    fi
    
    # 문법 검사
    if ! bash -n "$script_path" 2>/dev/null; then
        echo "  ❌ 문법 오류 — 롤백"
        local latest_backup=$(ls -t "$BACKUP_DIR/${target}."*.bak 2>/dev/null | head -1)
        if [ -n "$latest_backup" ]; then
            cp "$latest_backup" "$script_path"
            echo "  ✅ 롤백 완료"
        fi
        return 1
    fi
    
    echo "  ✅ 적용 완료: $target"
    
    # 이력 기록
    echo "" >> "$MEMORY/evolution-log.md"
    echo "## [$TODAY] 제안 적용" >> "$MEMORY/evolution-log.md"
    echo "- **제안**: $(basename "$proposal_file")" >> "$MEMORY/evolution-log.md"
    echo "- **대상**: $target" >> "$MEMORY/evolution-log.md"
    echo "- **상태**: 적용됨" >> "$MEMORY/evolution-log.md"
    
    # 상태 업데이트
    python3 -c "
import json, os
state_file = '$STATE_FILE'
if os.path.exists(state_file):
    with open(state_file) as f:
        state = json.load(f)
    state['selfModificationCount'] = state.get('selfModificationCount', 0) + 1
    state['lastModificationVerdict'] = {
        'target': '$target',
        'proposal': '$(basename "$proposal_file")',
        'verdict': 'APPLIED',
        'timestamp': '$TIMESTAMP'
    }
    with open(state_file, 'w') as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
"
    return 0
}

# ─── 3. 제안 생성 (AI가 읽을 수 있는 포맷) ───
generate_proposals() {
    echo "📋 자기수정 제안 생성..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # metacognitive.sh에서 생성된 제안이 있는지 확인
    python3 << 'PYEOF'
import json, os

state_file = os.environ.get('STATE_FILE', os.path.expanduser('~/Projects/openclaw/memory/learning-state.json'))
proposals_dir = os.environ.get('PROPOSALS_DIR', os.path.expanduser('~/Projects/openclaw/memory/proposals'))

if os.path.exists(state_file):
    with open(state_file) as f:
        state = json.load(f)

proposals = state.get('metacognitiveProposals', [])
high_priority = [p for p in proposals if p.get('priority') == 'high']

if not high_priority:
    print("  ℹ️ 고우선순위 제안 없음 — 자기수정 불필요")
    print("")
    print("  💡 AI 세션에서 다음을 실행하여 수동 제안 생성 가능:")
    print("     1. scripts/evolve.sh daily 실행하여 현재 상태 확인")
    print("     2. metacognitive-log.md 검토")
    print("     3. 구체적 개선안을 memory/proposals/ 에 .md 파일로 작성")
    print("     4. self-modify.sh --apply <제안파일> 로 적용")
else:
    print(f"  📋 {len(high_priority)}개 고우선순위 제안 대기 중:")
    for p in high_priority:
        icon = {'high': '🔴', 'medium': '🟡', 'low': '🟢'}.get(p.get('priority', 'low'), '⚪')
        print(f"    {icon} [{p.get('id', '?')}] {p.get('description', '')}")
        print(f"       → {p.get('action', '')}")
    print("")
    print("  ⚠️ 제안은 AI 세션에서 검토 후 적용하세요:")
    print("     self-modify.sh --apply <제안파일>")
PYEOF
}

# ─── 4. 이력 정리 ───
cleanup_old_backups() {
    BACKUP_COUNT=$(ls "$BACKUP_DIR/"*.bak 2>/dev/null | wc -l)
    if [ "$BACKUP_COUNT" -gt 30 ]; then
        echo "  🧹 오래된 백업 정리..."
        ls -t "$BACKUP_DIR/"*.bak | tail -n +31 | xargs rm -f
        echo "  ✅ 정리 완료"
    fi
}

# ─── 메인 ───
echo "🔄 HyperAgents 자기수정 ($TODAY)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

case "${1:-}" in
    --apply)
        if [ -z "${2:-}" ]; then
            echo "사용법: self-modify.sh --apply <제안파일>"
            exit 1
        fi
        apply_proposal "$2"
        ;;
    --dry-run)
        echo "  🔍 [DRY RUN] 제안만 생성 (적용하지 않음)"
        generate_proposals
        ;;
    "")
        generate_proposals
        cleanup_old_backups
        ;;
    *)
        echo "사용법: self-modify.sh [--dry-run] [--apply <제안파일>]"
        exit 1
        ;;
esac

echo ""
echo "✅ 자기수정 완료"
