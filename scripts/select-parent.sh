#!/bin/bash
# select-parent.sh — DGM 부모 노드 선택 v4
#
# DGM 논문 공식 (arxiv 2505.22954):
#   "선택 확률 ∝ performance × children_with_functional_editing"
#
# 본 구현 (운영 지표 기반 적응):
#   weight_i = sigmoid((score_i-50)/15) × (1 + novelty_i) × underexplored_i
#     - sigmoid: 낮은 점수도 0이 아닌 기회 (local optimum 탈출)
#     - novelty ∈ [0,1]: 다른 노드와 script hash 평균 거리 (더 다를수록 ↑)
#     - underexplored = 1/(1 + num_children): 덜 탐색된 노드 우대
#
# 사용:
#   select-parent.sh                          # 가중치 샘플링 (stdout: node_id)
#   select-parent.sh --deterministic          # 최대 가중치 선택
#   select-parent.sh --exclude-recent N       # 최근 N세대 제외
#   select-parent.sh --min-score N            # 점수 하한
#   select-parent.sh --explain                # 후보별 가중치 테이블
#   select-parent.sh --seed N                 # 난수 seed (재현성)

set -euo pipefail

WORKSPACE="$HOME/Projects/openclaw"
ARCHIVE_DIR="$WORKSPACE/memory/agent-archive"
NODES_DIR="$ARCHIVE_DIR/nodes"
INDEX_FILE="$ARCHIVE_DIR/index.json"

DETERMINISTIC=0
EXPLAIN=0
EXCLUDE_RECENT=0
MIN_SCORE=0
SEED=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deterministic) DETERMINISTIC=1; shift ;;
        --explain) EXPLAIN=1; shift ;;
        --exclude-recent) EXCLUDE_RECENT="$2"; shift 2 ;;
        --min-score) MIN_SCORE="$2"; shift 2 ;;
        --seed) SEED="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,25p' "$0"
            exit 0
            ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

if [ ! -f "$INDEX_FILE" ]; then
    echo "❌ 아카이브 없음. archive.sh init 먼저 실행" >&2
    exit 1
fi

INDEX_FILE="$INDEX_FILE" NODES_DIR="$NODES_DIR" \
DETERMINISTIC="$DETERMINISTIC" EXPLAIN="$EXPLAIN" \
EXCLUDE_RECENT="$EXCLUDE_RECENT" MIN_SCORE="$MIN_SCORE" SEED="$SEED" \
python3 << 'PYEOF'
import json, math, os, random, sys

INDEX_FILE = os.environ['INDEX_FILE']
NODES_DIR = os.environ['NODES_DIR']
DETERMINISTIC = int(os.environ['DETERMINISTIC'])
EXPLAIN = int(os.environ['EXPLAIN'])
EXCLUDE_RECENT = int(os.environ['EXCLUDE_RECENT'])
MIN_SCORE = int(os.environ['MIN_SCORE'])
SEED = os.environ['SEED']

if SEED:
    random.seed(int(SEED))

def sigmoid(x):
    return 1.0 / (1.0 + math.exp(-x))

def hash_distance(h1, h2):
    """sha256 hex 문자열 간 정규화 Hamming (0~1)"""
    if not h1 or not h2 or len(h1) != len(h2):
        return 1.0
    matches = sum(1 for a, b in zip(h1, h2) if a == b)
    return 1.0 - (matches / len(h1))

def script_avg_distance(a_hashes, b_hashes):
    """두 노드의 script_hashes 간 평균 거리"""
    common = set(a_hashes.keys()) & set(b_hashes.keys())
    if not common:
        return 1.0  # 공통 스크립트 없음 = 매우 다름
    return sum(hash_distance(a_hashes[k], b_hashes[k]) for k in common) / len(common)

def load_meta(nid):
    p = os.path.join(NODES_DIR, nid, 'meta.json')
    if not os.path.exists(p):
        return None
    with open(p) as f:
        return json.load(f)

with open(INDEX_FILE) as f:
    idx = json.load(f)

nodes = idx.get('nodes', [])
if not nodes:
    print("❌ 아카이브 비어있음", file=sys.stderr)
    sys.exit(1)

# 제외 필터 적용
total = len(nodes)
eligible_entries = nodes[:]

if EXCLUDE_RECENT > 0:
    eligible_entries = eligible_entries[: max(0, total - EXCLUDE_RECENT)]

if MIN_SCORE > 0:
    eligible_entries = [n for n in eligible_entries if n['score'] >= MIN_SCORE]

if not eligible_entries:
    print("❌ 조건에 맞는 노드 없음", file=sys.stderr)
    sys.exit(1)

# 모든 meta 로드
metas = {}
for n in eligible_entries:
    m = load_meta(n['id'])
    if m:
        metas[n['id']] = m

if not metas:
    print("❌ meta 로드 실패", file=sys.stderr)
    sys.exit(1)

# 가중치 계산
candidates = []
node_ids = list(metas.keys())
for nid in node_ids:
    m = metas[nid]
    score = m.get('score', 0)

    # 1) score factor: sigmoid((score-50)/15)
    score_factor = sigmoid((score - 50) / 15.0)

    # 2) novelty factor: 다른 모든 노드와의 평균 script 거리
    my_hashes = m.get('scriptHashes', {})
    if len(node_ids) > 1 and my_hashes:
        distances = []
        for other_id in node_ids:
            if other_id == nid:
                continue
            other_hashes = metas[other_id].get('scriptHashes', {})
            if other_hashes:
                distances.append(script_avg_distance(my_hashes, other_hashes))
        novelty = sum(distances) / len(distances) if distances else 0.5
    else:
        novelty = 0.5  # 첫 노드: 중립
    novelty_factor = 1.0 + novelty

    # 3) underexplored factor: 1 / (1 + children 수)
    num_children = len(m.get('children', []))
    underexplored_factor = 1.0 / (1.0 + num_children)

    weight = score_factor * novelty_factor * underexplored_factor
    candidates.append({
        'id': nid,
        'score': score,
        'score_factor': score_factor,
        'novelty': novelty,
        'novelty_factor': novelty_factor,
        'children': num_children,
        'underexplored_factor': underexplored_factor,
        'weight': weight,
    })

# 정렬 (explain용)
candidates.sort(key=lambda x: x['weight'], reverse=True)

if EXPLAIN:
    print(f"  🧮 후보 가중치 (n={len(candidates)})", file=sys.stderr)
    print(f"  {'ID':<6} {'Score':<6} {'SF':<6} {'Novelty':<8} {'Underex':<8} {'Weight':<8}", file=sys.stderr)
    print(f"  {'-'*6} {'-'*6} {'-'*6} {'-'*8} {'-'*8} {'-'*8}", file=sys.stderr)
    for c in candidates:
        print(f"  {c['id']:<6} {c['score']:<6} {c['score_factor']:<6.3f} {c['novelty']:<8.3f} {c['underexplored_factor']:<8.3f} {c['weight']:<8.4f}", file=sys.stderr)

# 선택
if DETERMINISTIC:
    chosen = candidates[0]
else:
    weights = [c['weight'] for c in candidates]
    total_w = sum(weights)
    if total_w <= 0:
        chosen = candidates[0]
    else:
        r = random.random() * total_w
        cumulative = 0.0
        chosen = candidates[-1]
        for c in candidates:
            cumulative += c['weight']
            if r <= cumulative:
                chosen = c
                break

if EXPLAIN:
    print(f"  🎯 선택: {chosen['id']} (weight={chosen['weight']:.4f})", file=sys.stderr)

# stdout에는 node_id만 (다른 스크립트가 파싱)
print(chosen['id'])
PYEOF
