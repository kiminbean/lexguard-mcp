#!/bin/bash
# archive.sh — HyperAgent 진화 아카이브 v4
#
# DGM 논문 (arxiv 2505.22954) + HyperAgents (arxiv 2603.19461) 기반.
# 모든 에이전트 변형체를 score/lineage/benchmark와 함께 저장.
# 부모선택(select-parent.sh) + 제안생성(propose-mutation.sh)의 기반 구조.
#
# 디렉토리:
#   memory/agent-archive/
#     index.json                   # 전체 노드 요약 인덱스
#     nodes/<NODE_ID>/
#       meta.json                  # 노드 메타데이터 (score, parent, children, hashes, benchmark)
#       scripts/<script>           # 스크립트 스냅샷 (진화 대상 전체)
#
# 사용:
#   archive.sh init
#   archive.sh add-node --score N [--parent ID] [--benchmark FILE] [--reason TEXT]
#   archive.sh get-node ID
#   archive.sh list-nodes [--format json|text]
#   archive.sh get-lineage ID
#   archive.sh score-stats
#   archive.sh restore-node ID [--dry-run]

set -euo pipefail

WORKSPACE="$HOME/Projects/openclaw"
SCRIPTS_DIR="$WORKSPACE/scripts"
ARCHIVE_DIR="$WORKSPACE/memory/agent-archive"
NODES_DIR="$ARCHIVE_DIR/nodes"
INDEX_FILE="$ARCHIVE_DIR/index.json"

# 아카이브 대상 스크립트 (self-modify.sh ALLOWED_TARGETS와 동기화)
ARCHIVE_SCRIPTS=(
    "evolve.sh"
    "metacognitive.sh"
    "self-modify.sh"
    "cron-audit.sh"
    "notify-hyperagent.sh"
    "archive.sh"
    "select-parent.sh"
    "propose-mutation.sh"
    "benchmark.sh"
    "auto-skill.sh"
    "prediction-tracker.sh"
)

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

init_archive() {
    mkdir -p "$NODES_DIR"
    if [ ! -f "$INDEX_FILE" ]; then
        echo '{"schemaVersion":4,"nodes":[],"latestId":null,"totalNodes":0}' > "$INDEX_FILE"
        echo "✅ 아카이브 초기화: $ARCHIVE_DIR"
    else
        echo "ℹ️ 아카이브 이미 존재: $ARCHIVE_DIR"
    fi
}

next_id() {
    INDEX="$INDEX_FILE" python3 -c "
import json, os
with open(os.environ['INDEX']) as f: idx = json.load(f)
print(f\"{idx['totalNodes']+1:04d}\")
"
}

add_node() {
    local parent=""
    local score=""
    local benchmark_file=""
    local reason=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --parent) parent="$2"; shift 2 ;;
            --score) score="$2"; shift 2 ;;
            --benchmark) benchmark_file="$2"; shift 2 ;;
            --reason) reason="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done

    [ -n "$score" ] || { echo "❌ --score 필수" >&2; return 1; }
    [ -f "$INDEX_FILE" ] || init_archive

    local node_id
    node_id=$(next_id)
    local node_dir="$NODES_DIR/$node_id"
    mkdir -p "$node_dir/scripts"

    local snapshot_count=0
    for script in "${ARCHIVE_SCRIPTS[@]}"; do
        local src="$SCRIPTS_DIR/$script"
        if [ -f "$src" ]; then
            cp "$src" "$node_dir/scripts/"
            snapshot_count=$((snapshot_count + 1))
        fi
    done

    # sha256 해시 맵 (novelty 계산용)
    local sha_map
    sha_map=$(NODE_DIR="$node_dir" python3 -c "
import os, hashlib, json
scripts = {}
scripts_dir = os.path.join(os.environ['NODE_DIR'], 'scripts')
if os.path.isdir(scripts_dir):
    for fname in sorted(os.listdir(scripts_dir)):
        path = os.path.join(scripts_dir, fname)
        if os.path.isfile(path):
            with open(path, 'rb') as f:
                scripts[fname] = hashlib.sha256(f.read()).hexdigest()
print(json.dumps(scripts))
")

    # benchmark 결과 (선택)
    local benchmark="{}"
    if [ -n "$benchmark_file" ] && [ -f "$benchmark_file" ]; then
        benchmark=$(cat "$benchmark_file")
    fi

    # meta.json 생성
    NODE_DIR="$node_dir" NODE_ID="$node_id" PARENT="$parent" SCORE="$score" \
    TIMESTAMP="$TIMESTAMP" REASON="$reason" SHA_MAP="$sha_map" \
    BENCHMARK="$benchmark" SNAPSHOT_COUNT="$snapshot_count" python3 << 'PYEOF'
import os, json
meta = {
    "id": os.environ['NODE_ID'],
    "parent": os.environ['PARENT'] or None,
    "timestamp": os.environ['TIMESTAMP'],
    "score": int(os.environ['SCORE']),
    "reason": os.environ['REASON'] or "",
    "snapshotCount": int(os.environ['SNAPSHOT_COUNT']),
    "scriptHashes": json.loads(os.environ['SHA_MAP']),
    "benchmark": json.loads(os.environ['BENCHMARK']),
    "children": [],
}
with open(os.path.join(os.environ['NODE_DIR'], 'meta.json'), 'w') as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
PYEOF

    # 인덱스 업데이트 + 부모의 children 추가
    INDEX="$INDEX_FILE" NODE_ID="$node_id" PARENT="$parent" SCORE="$score" \
    TIMESTAMP="$TIMESTAMP" NODES_DIR="$NODES_DIR" python3 << 'PYEOF'
import json, os
with open(os.environ['INDEX']) as f: idx = json.load(f)

entry = {
    "id": os.environ['NODE_ID'],
    "parent": os.environ['PARENT'] or None,
    "timestamp": os.environ['TIMESTAMP'],
    "score": int(os.environ['SCORE']),
}
idx['nodes'].append(entry)
idx['totalNodes'] = len(idx['nodes'])
idx['latestId'] = os.environ['NODE_ID']

parent = os.environ['PARENT']
if parent:
    pm_path = os.path.join(os.environ['NODES_DIR'], parent, 'meta.json')
    if os.path.exists(pm_path):
        with open(pm_path) as f: pm = json.load(f)
        if os.environ['NODE_ID'] not in pm.get('children', []):
            pm.setdefault('children', []).append(os.environ['NODE_ID'])
        with open(pm_path, 'w') as f:
            json.dump(pm, f, indent=2, ensure_ascii=False)

with open(os.environ['INDEX'], 'w') as f:
    json.dump(idx, f, indent=2, ensure_ascii=False)

print(f"✅ 노드 생성: {os.environ['NODE_ID']} (parent={parent or 'ROOT'}, score={os.environ['SCORE']}, snapshots={os.environ.get('SNAPSHOT_COUNT','?')})")
PYEOF
}

get_node() {
    local id="${1:-}"
    [ -n "$id" ] || { echo "❌ node id 필요" >&2; return 1; }
    local path="$NODES_DIR/$id/meta.json"
    if [ -f "$path" ]; then
        cat "$path"
    else
        echo "❌ 노드 없음: $id" >&2
        return 1
    fi
}

list_nodes() {
    local format="text"
    if [ "${1:-}" = "--format" ]; then
        format="${2:-text}"
    fi
    [ -f "$INDEX_FILE" ] || { echo "아카이브 없음 (archive.sh init)"; return 1; }

    if [ "$format" = "json" ]; then
        cat "$INDEX_FILE"
    else
        INDEX="$INDEX_FILE" python3 << 'PYEOF'
import json, os
with open(os.environ['INDEX']) as f: idx = json.load(f)
nodes = idx.get('nodes', [])
if not nodes:
    print("  ℹ️ 노드 없음")
else:
    print(f"  📦 총 {len(nodes)}개 노드 (schema v{idx.get('schemaVersion','?')})")
    print(f"  {'ID':<6} {'Parent':<8} {'Score':<6} Timestamp")
    print(f"  {'-'*6} {'-'*8} {'-'*6} {'-'*20}")
    for n in nodes:
        parent = n.get('parent') or 'ROOT'
        print(f"  {n['id']:<6} {parent:<8} {n['score']:<6} {n['timestamp']}")
    print(f"\n  🏁 latest: {idx.get('latestId','?')}")
PYEOF
    fi
}

get_lineage() {
    local id="${1:-}"
    [ -n "$id" ] || { echo "❌ node id 필요" >&2; return 1; }
    NODES_DIR="$NODES_DIR" START_ID="$id" python3 << 'PYEOF'
import os, json
nodes_dir = os.environ['NODES_DIR']
current = os.environ['START_ID']
lineage = []
visited = set()
while current and current not in visited:
    visited.add(current)
    path = os.path.join(nodes_dir, current, 'meta.json')
    if not os.path.exists(path):
        break
    with open(path) as f: meta = json.load(f)
    lineage.append({
        'id': meta['id'],
        'score': meta['score'],
        'parent': meta.get('parent'),
        'reason': meta.get('reason', '')[:40],
    })
    current = meta.get('parent')

if not lineage:
    print(f"  ❌ 노드 없음: {os.environ['START_ID']}")
else:
    print(f"  🧬 계보 (최신 → 루트, 깊이={len(lineage)}):")
    for entry in lineage:
        parent = entry['parent'] or 'ROOT'
        reason = f" ─ {entry['reason']}" if entry['reason'] else ""
        print(f"    {entry['id']} (score={entry['score']}) ← {parent}{reason}")
PYEOF
}

score_stats() {
    [ -f "$INDEX_FILE" ] || { echo "아카이브 없음"; return 1; }
    INDEX="$INDEX_FILE" python3 << 'PYEOF'
import json, os, statistics
with open(os.environ['INDEX']) as f: idx = json.load(f)
scores = [n['score'] for n in idx.get('nodes', [])]
if not scores:
    print("  ℹ️ 데이터 없음")
else:
    print(f"  📊 score stats (n={len(scores)})")
    print(f"    min:    {min(scores)}")
    print(f"    max:    {max(scores)}")
    print(f"    mean:   {statistics.mean(scores):.1f}")
    if len(scores) > 1:
        print(f"    stdev:  {statistics.stdev(scores):.1f}")
    print(f"    latest: {scores[-1]}")
    # 상위 3 / 하위 3
    sorted_nodes = sorted(idx['nodes'], key=lambda x: x['score'], reverse=True)
    print("    top 3:")
    for n in sorted_nodes[:3]:
        print(f"      {n['id']} score={n['score']}")
    if len(sorted_nodes) > 3:
        print("    bottom 3:")
        for n in sorted_nodes[-3:]:
            print(f"      {n['id']} score={n['score']}")
PYEOF
}

restore_node() {
    local id="${1:-}"
    local dry_run="${2:-}"
    [ -n "$id" ] || { echo "❌ node id 필요" >&2; return 1; }

    local node_dir="$NODES_DIR/$id"
    if [ ! -d "$node_dir/scripts" ]; then
        echo "❌ 노드 스냅샷 없음: $id" >&2
        return 1
    fi

    if [ "$dry_run" = "--dry-run" ]; then
        echo "  🔍 [DRY RUN] 복원 대상 ($id):"
        for f in "$node_dir/scripts/"*; do
            [ -f "$f" ] && echo "    ← $(basename "$f")"
        done
        return 0
    fi

    echo "  💾 현재 상태를 자동 백업 노드로 저장 중..."
    add_node --score "${PRE_RESTORE_SCORE:-0}" --reason "pre-restore-to-$id"

    for f in "$node_dir/scripts/"*; do
        local fname
        fname=$(basename "$f")
        cp "$f" "$SCRIPTS_DIR/$fname"
        echo "  ✅ 복원: $fname"
    done

    echo ""
    echo "  🔄 노드 $id 복원 완료"
}

# ─── Main ───
case "${1:-}" in
    init)
        init_archive
        ;;
    add-node)
        shift
        add_node "$@"
        ;;
    get-node)
        get_node "${2:-}"
        ;;
    list-nodes)
        shift
        list_nodes "$@"
        ;;
    get-lineage)
        get_lineage "${2:-}"
        ;;
    score-stats)
        score_stats
        ;;
    restore-node)
        restore_node "${2:-}" "${3:-}"
        ;;
    *)
        cat << 'EOF'
사용법: archive.sh <command> [options]

Commands:
  init                              아카이브 초기화
  add-node --score N [--parent ID] [--benchmark FILE] [--reason TEXT]
                                    새 노드 추가 (스크립트 스냅샷 포함)
  get-node ID                       노드 meta.json 조회
  list-nodes [--format json|text]   전체 노드 목록
  get-lineage ID                    계보 추적 (부모 체인)
  score-stats                       점수 통계 (min/max/mean/top/bottom)
  restore-node ID [--dry-run]       특정 노드 상태로 복원 (자동 백업 포함)

예시:
  archive.sh init
  archive.sh add-node --score 65 --reason "v3 initial deployment"
  archive.sh list-nodes
  archive.sh restore-node 0001 --dry-run
EOF
        ;;
esac
