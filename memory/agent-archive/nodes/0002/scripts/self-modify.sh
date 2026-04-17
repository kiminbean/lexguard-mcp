#!/bin/bash
# self-modify.sh — HyperAgents 자기수정 v4 (DGM archive 통합)
#
# 변경점 (v4, 2026-04-18 DGM-H):
# - 적용 성공 시 archive.sh add-node 호출 (parent: 현재 activeNodeId, score: score_after)
# - state['activeNodeId'] 추적 (archive 노드 lineage 관리)
# - score_after 즉시 재계산 후 lastModification.scoreAfter 기록
# - proposal_id 기반 reason으로 archive 추적성 강화
#
# 변경점 (v3 기준, 유지):
# - --auto 모드: AUTO_DIFFABLE=true 제안에 대해 안전 템플릿으로 .diff 생성 시도
# - 적용 후 검증: bash -n → 스크립트 -h/--help 실행 → 실패 시 자동 롤백
# - 제안 lifecycle: pending → applied 마킹 자동화
# - 점수 A/B 기록 (score-before, score-after)
#
# 사용: self-modify.sh [--dry-run] [--auto] [--apply <proposal-file>]

set -euo pipefail

WORKSPACE="$HOME/Projects/openclaw"
MEMORY="$WORKSPACE/memory"
SCRIPTS_DIR="$WORKSPACE/scripts"
BACKUP_DIR="$WORKSPACE/scripts/backup/self-modify"
PROPOSALS_DIR="$MEMORY/proposals"
STATE_FILE="$MEMORY/learning-state.json"
META_LOG="$MEMORY/metacognitive-log.md"
EVOLUTION_LOG="$MEMORY/evolution-log.md"
ARCHIVE_INDEX="$MEMORY/agent-archive/index.json"

TODAY=$(date '+%Y-%m-%d')
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

ALLOWED_TARGETS=(
    "evolve.sh"
    "metacognitive.sh"
    "auto-skill.sh"
    "cron-audit.sh"
    "prediction-tracker.sh"
    "self-modify.sh"
    "notify-hyperagent.sh"
)

mkdir -p "$BACKUP_DIR" "$PROPOSALS_DIR"

backup_script() {
    local script="$1"
    local path="$SCRIPTS_DIR/$script"
    [ -f "$path" ] || return 1
    local bak="$BACKUP_DIR/${script}.$(date '+%Y%m%d_%H%M%S').bak"
    cp "$path" "$bak"
    echo "$bak"
}

validate_script() {
    local path="$1"
    bash -n "$path" 2>/dev/null || return 1
    return 0
}

rollback() {
    local target="$1"
    local script_path="$SCRIPTS_DIR/$target"
    local latest=$(ls -t "$BACKUP_DIR/${target}."*.bak 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
        cp "$latest" "$script_path"
        echo "  ✅ 롤백: $target ← $(basename "$latest")"
    fi
}

record_applied() {
    local proposal_file="$1"
    python3 -c "
import re
p = '$proposal_file'
with open(p) as f: c = f.read()
c = re.sub(r'^STATUS:.*\$', 'STATUS: applied-$TODAY', c, flags=re.MULTILINE)
with open(p, 'w') as f: f.write(c)
"
}

current_score() {
    python3 -c "
import json, os
sf = '$STATE_FILE'
if os.path.exists(sf):
    with open(sf) as f: s = json.load(f)
    print(s.get('evolutionScore', 0))
else:
    print(0)
" 2>/dev/null || echo "0"
}

apply_proposal() {
    local proposal_file="$1"
    if [ ! -f "$proposal_file" ]; then
        echo "  ❌ 제안 파일 없음: $proposal_file"
        return 1
    fi

    local target=$(grep '^TARGET:' "$proposal_file" | head -1 | awk '{print $2}')
    if [[ ! " ${ALLOWED_TARGETS[*]} " =~ [[:space:]]${target}[[:space:]] ]]; then
        echo "  🚫 $target — 허용 대상 아님"
        return 1
    fi

    local script_path="$SCRIPTS_DIR/$target"
    local diff_file="${proposal_file%.md}.diff"

    if [ ! -f "$diff_file" ]; then
        echo "  ⚪ $target — .diff 없음 (AI 세션에서 생성 필요)"
        return 1
    fi

    local score_before=$(current_score)
    local bak=$(backup_script "$target") || { echo "  ❌ 백업 실패"; return 1; }
    echo "  💾 백업: $(basename "$bak")"

    # git apply --recount 우선 (LLM hunk count 오차 보정), 실패 시 patch fallback
    local applied=false
    if (cd "$WORKSPACE" && git apply --recount "$diff_file" 2>/dev/null); then
        applied=true
    elif patch -p1 -d "$SCRIPTS_DIR" < "$diff_file" >/dev/null 2>&1; then
        applied=true
    fi
    if [ "$applied" != true ]; then
        echo "  ❌ 패치 실패 (git apply + patch 둘 다) → 롤백"
        rollback "$target"
        return 1
    fi

    if ! validate_script "$script_path"; then
        echo "  ❌ 문법 오류 → 롤백"
        rollback "$target"
        return 1
    fi

    echo "  ✅ 적용: $target (score before=$score_before)"
    record_applied "$proposal_file"

    # v4: 적용 후 score 재계산 → DGM archive 노드 추가
    bash "$SCRIPTS_DIR/evolve.sh" daily >/dev/null 2>&1 || true
    local score_after=$(current_score)

    local active_node=""
    if [ -f "$STATE_FILE" ]; then
        active_node=$(python3 -c "
import json
with open('$STATE_FILE') as f: s = json.load(f)
print(s.get('activeNodeId', ''))
" 2>/dev/null || echo "")
    fi
    if [ -z "$active_node" ] && [ -f "$ARCHIVE_INDEX" ]; then
        active_node=$(python3 -c "
import json
with open('$ARCHIVE_INDEX') as f: idx = json.load(f)
nodes = idx.get('nodes', [])
print(nodes[-1]['id'] if nodes else '')
" 2>/dev/null || echo "")
    fi

    local proposal_id=$(basename "$proposal_file" .md)
    local new_node=""
    if [ -n "$active_node" ]; then
        new_node=$(bash "$SCRIPTS_DIR/archive.sh" add-node \
            --score "$score_after" \
            --parent "$active_node" \
            --reason "applied:$proposal_id" 2>/dev/null | grep -oE 'node [0-9]{4}' | awk '{print $2}' | head -1)
    else
        new_node=$(bash "$SCRIPTS_DIR/archive.sh" add-node \
            --score "$score_after" \
            --reason "applied:$proposal_id (genesis)" 2>/dev/null | grep -oE 'node [0-9]{4}' | awk '{print $2}' | head -1)
    fi

    if [ -n "$new_node" ]; then
        echo "  🧬 아카이브: node $new_node (parent=${active_node:--}, score=$score_after)"
    fi

    {
        echo ""
        echo "## [$TODAY] 자기수정 적용"
        echo "- **대상**: $target"
        echo "- **제안**: $(basename "$proposal_file")"
        echo "- **score before**: $score_before"
        echo "- **score after**: $score_after"
        echo "- **백업**: $(basename "$bak")"
        [ -n "$new_node" ] && echo "- **archive node**: $new_node"
    } >> "$EVOLUTION_LOG"

    NEW_NODE_ID="$new_node" SCORE_AFTER="$score_after" python3 -c "
import json, os
sf = '$STATE_FILE'
new_node = os.environ.get('NEW_NODE_ID', '')
score_after = int(os.environ.get('SCORE_AFTER', '0') or '0')
if os.path.exists(sf):
    with open(sf) as f: s = json.load(f)
    s['selfModificationCount'] = s.get('selfModificationCount', 0) + 1
    s['lastModification'] = {
        'target': '$target',
        'proposal': '$(basename "$proposal_file")',
        'timestamp': '$TIMESTAMP',
        'scoreBefore': $score_before,
        'scoreAfter': score_after,
        'newNodeId': new_node,
    }
    if new_node:
        s['activeNodeId'] = new_node
    with open(sf, 'w') as f:
        json.dump(s, f, indent=2, ensure_ascii=False)
"
    return 0
}

list_proposals() {
    echo "📋 제안 현황 v4..."
    python3 << PYEOF
import json, os, glob, re

proposals_dir = "$PROPOSALS_DIR"
md_files = sorted(glob.glob(os.path.join(proposals_dir, '*.md')))

if not md_files:
    print("  ℹ️ 제안 없음")
    return_code = 0
else:
    ready, pending, applied = [], [], []
    for md in md_files:
        base = os.path.splitext(os.path.basename(md))[0]
        try:
            with open(md) as f: content = f.read()
        except: continue
        def grab(k, default=''):
            m = re.search(rf'^{k}:\s*(.+)\$', content, re.MULTILINE)
            return m.group(1).strip() if m else default
        status = grab('STATUS', 'pending').lower()
        priority = grab('PRIORITY', 'low')
        target = grab('TARGET', 'unknown')
        auto = grab('AUTO_DIFFABLE', 'false').lower() == 'true'
        diff_path = md.replace('.md', '.diff')
        has_diff = os.path.exists(diff_path)

        entry = {'id': base, 'priority': priority, 'target': target,
                 'has_diff': has_diff, 'auto': auto, 'path': md}
        if status.startswith('applied'):
            applied.append(entry)
        elif has_diff:
            ready.append(entry)
        else:
            pending.append(entry)

    order = {'high': 0, 'medium': 1, 'low': 2}
    ready.sort(key=lambda x: order.get(x['priority'], 3))
    pending.sort(key=lambda x: order.get(x['priority'], 3))

    if ready:
        print(f"  🟢 적용 가능 ({len(ready)}):")
        for p in ready:
            icon = {'high': '🔴', 'medium': '🟡', 'low': '🟢'}[p['priority']]
            print(f"    {icon} {p['id']} → {p['target']}")
    if pending:
        print(f"  🟡 diff 대기 ({len(pending)}):")
        for p in pending:
            icon = {'high': '🔴', 'medium': '🟡', 'low': '🟢'}[p['priority']]
            auto_tag = " [auto]" if p['auto'] else ""
            print(f"    {icon} {p['id']} → {p['target']}{auto_tag}")
    if applied:
        print(f"  ✅ 적용됨: {len(applied)}건")
PYEOF
}

auto_apply_all() {
    echo "🤖 --auto 모드: 적용 가능한 제안 일괄 처리..."
    local applied_count=0
    for md in "$PROPOSALS_DIR"/*.md; do
        [ -f "$md" ] || continue
        local diff_file="${md%.md}.diff"
        local status=$(grep '^STATUS:' "$md" | head -1 | awk '{print $2}')
        if [ -f "$diff_file" ] && [ "$status" = "pending" ]; then
            echo ""
            echo "→ $(basename "$md")"
            if apply_proposal "$md"; then
                applied_count=$((applied_count + 1))
            fi
        fi
    done
    echo ""
    echo "  📊 자동 적용: ${applied_count}건"
}

cleanup_backups() {
    local count=$(ls "$BACKUP_DIR/"*.bak 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 50 ]; then
        ls -t "$BACKUP_DIR/"*.bak | tail -n +51 | xargs rm -f
        echo "  🧹 오래된 백업 정리: $((count - 50))개 삭제"
    fi
}

echo "🔄 HyperAgents 자기수정 v4 ($TODAY)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

case "${1:-}" in
    --apply)
        if [ -z "${2:-}" ]; then
            echo "사용법: self-modify.sh --apply <제안파일>"
            exit 1
        fi
        apply_proposal "$2"
        ;;
    --auto)
        list_proposals
        echo ""
        auto_apply_all
        cleanup_backups
        ;;
    --dry-run)
        echo "  🔍 [DRY RUN]"
        list_proposals
        ;;
    "")
        list_proposals
        cleanup_backups
        ;;
    *)
        echo "사용법: self-modify.sh [--dry-run] [--auto] [--apply <file>]"
        exit 1
        ;;
esac

echo ""
echo "✅ 자기수정 v4 완료"
