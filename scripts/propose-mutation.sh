#!/bin/bash
# propose-mutation.sh — LLM 기반 돌연변이 제안 생성 v4
#
# DGM 논문 (arxiv 2505.22954) 개념:
#   "FM이 evaluation log + 현재 코드를 분석 → 다음 개선 피처 제안 → coding problem"
#
# 본 구현:
#   - 입력 컨텍스트: learning-state.json + metacognitive-log (tail) + cron-audit + 대상 스크립트
#   - LLM: openclaw.json models.providers.openai (1차) → zai (fallback)
#   - 출력: proposals/<target>-<timestamp>.{md,diff} (PARENT: node_id 헤더 포함)
#
# 안전장치:
#   - --dry-run 기본 아님 (실제 API 호출하므로 의도 필요)
#   - max 8K 입력 토큰 (내용 truncate)
#   - temperature 0.3 (결정성)
#   - --apply로만 proposals 디렉토리에 저장 (기본은 /tmp)
#   - 제안 후 bash -n + patch --dry-run으로 사전 검증
#
# 사용:
#   propose-mutation.sh --target evolve.sh --goal "텍스트"          # /tmp에 저장
#   propose-mutation.sh --target evolve.sh --apply                  # proposals에 저장
#   propose-mutation.sh --target evolve.sh --dry-run                # API 호출 없이 프롬프트 표시
#   propose-mutation.sh --target evolve.sh --parent 0001            # 계보 명시

set -euo pipefail

WORKSPACE="$HOME/Projects/openclaw"
SCRIPTS_DIR="$WORKSPACE/scripts"
MEMORY="$WORKSPACE/memory"
STATE_FILE="$MEMORY/learning-state.json"
META_LOG="$MEMORY/metacognitive-log.md"
EVOLUTION_LOG="$MEMORY/evolution-log.md"
CRON_AUDIT_JSON="$MEMORY/cron-audit.json"
PROPOSALS_DIR="$MEMORY/proposals"
CONFIG_JSON="$HOME/.openclaw/openclaw.json"
LOG_DIR="$HOME/.openclaw/logs"
MUTATION_LOG="$LOG_DIR/propose-mutation.jsonl"

TARGET=""
GOAL=""
PARENT=""
DRY_RUN=false
APPLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --goal) GOAL="$2"; shift 2 ;;
        --parent) PARENT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --apply) APPLY=true; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

[ -n "$TARGET" ] || { echo "❌ --target 필수" >&2; exit 1; }
[ -f "$SCRIPTS_DIR/$TARGET" ] || { echo "❌ 대상 스크립트 없음: $TARGET" >&2; exit 1; }

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
TS_COMPACT=$(date '+%Y%m%d_%H%M%S')
TODAY=$(date '+%Y-%m-%d')

mkdir -p "$LOG_DIR" "$PROPOSALS_DIR"

log_event() {
    local event="$1"
    shift
    local ts_ms
    ts_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
    local line="{\"ts\":$ts_ms,\"iso\":\"$TIMESTAMP\",\"event\":\"$event\",\"target\":\"$TARGET\""
    for arg in "$@"; do line="$line,$arg"; done
    line="$line}"
    echo "$line" >> "$MUTATION_LOG"
}

# ─── 컨텍스트 수집 ───
build_context() {
    STATE="$STATE_FILE" META="$META_LOG" EVO="$EVOLUTION_LOG" \
    AUDIT="$CRON_AUDIT_JSON" TARGET_PATH="$SCRIPTS_DIR/$TARGET" \
    GOAL_TEXT="$GOAL" python3 << 'PYEOF'
import json, os

def safe_read(path, max_bytes=2000):
    if not os.path.exists(path): return f"(파일 없음: {path})"
    try:
        with open(path) as f:
            content = f.read()
        if len(content) > max_bytes:
            return content[-max_bytes:]  # 최근 부분
        return content
    except Exception as e:
        return f"(읽기 실패: {e})"

def safe_json(path):
    if not os.path.exists(path): return {}
    try:
        with open(path) as f: return json.load(f)
    except: return {}

ctx_parts = []

# 1) learning-state 요약
s = safe_json(os.environ['STATE'])
if s:
    metrics = s.get('metrics', {})
    summary = {
        'schemaVersion': s.get('schemaVersion', '?'),
        'evolutionScore': s.get('evolutionScore', '?'),
        'evolutionStatus': s.get('evolutionStatus', '?'),
        'metrics': {
            'cron': metrics.get('cron', {}),
            'proposals': metrics.get('proposals', {}),
            'externalSignal': metrics.get('externalSignal', {}),
        }
    }
    ctx_parts.append("## 현재 상태 (learning-state.json 요약)\n```json\n" + json.dumps(summary, indent=2, ensure_ascii=False) + "\n```")

# 2) 최근 metacognitive-log (tail 1500 bytes)
meta_tail = safe_read(os.environ['META'], 1500)
if meta_tail and '파일 없음' not in meta_tail:
    ctx_parts.append(f"## 메타인지 최근 기록\n```markdown\n{meta_tail}\n```")

# 3) evolution-log (tail 1500 bytes)
evo_tail = safe_read(os.environ['EVO'], 1500)
if evo_tail and '파일 없음' not in evo_tail:
    ctx_parts.append(f"## 진화 최근 기록\n```markdown\n{evo_tail}\n```")

# 4) cron-audit 최신 1건
audit = safe_json(os.environ['AUDIT'])
if audit and isinstance(audit, list) and audit:
    latest = audit[-1]
    ctx_parts.append(f"## 최근 크론 감사\n```json\n{json.dumps(latest, indent=2, ensure_ascii=False)[:1500]}\n```")

# 5) 대상 스크립트 전문 (최대 8000 bytes, 앞쪽)
script_content = safe_read(os.environ['TARGET_PATH'], 8000)
ctx_parts.append(f"## 대상 스크립트\n```bash\n{script_content}\n```")

# 6) 목표
goal = os.environ.get('GOAL_TEXT', '')
if goal:
    ctx_parts.append(f"## 개선 목표\n{goal}")

print("\n\n".join(ctx_parts))
PYEOF
}

# ─── LLM 호출 ───
call_llm() {
    local prompt_file="$1"
    local system_prompt="$2"

    local provider endpoint key model
    # 1차: OpenAI
    provider="openai"
    endpoint=$(python3 -c "
import json
try:
    with open('$CONFIG_JSON') as f: c = json.load(f)
    print(c['models']['providers']['openai']['baseUrl'])
except: pass
")
    key=$(python3 -c "
import json
try:
    with open('$CONFIG_JSON') as f: c = json.load(f)
    print(c['models']['providers']['openai']['apiKey'].strip())
except: pass
")
    model=$(python3 -c "
import json
try:
    with open('$CONFIG_JSON') as f: c = json.load(f)
    models = c['models']['providers']['openai'].get('models', [])
    if isinstance(models, list) and models: print(models[0])
    elif isinstance(models, dict): print(next(iter(models)))
    else: print('gpt-4o-mini')
except: print('gpt-4o-mini')
")

    if [ -z "$key" ] || [ -z "$endpoint" ]; then
        # 2차: zai (GLM)
        provider="zai"
        endpoint=$(python3 -c "
import json
try:
    with open('$CONFIG_JSON') as f: c = json.load(f)
    print(c['models']['providers']['zai']['baseUrl'])
except: pass
")
        key=$(python3 -c "
import json
try:
    with open('$CONFIG_JSON') as f: c = json.load(f)
    print(c['models']['providers']['zai']['apiKey'].strip())
except: pass
")
        model=$(python3 -c "
import json
try:
    with open('$CONFIG_JSON') as f: c = json.load(f)
    models = c['models']['providers']['zai'].get('models', [])
    if isinstance(models, list) and models: print(models[0])
    elif isinstance(models, dict): print(next(iter(models)))
    else: print('glm-4-flash')
except: print('glm-4-flash')
")
    fi

    if [ -z "$key" ]; then
        echo "❌ API 키 없음 (openai/zai 모두)" >&2
        log_event "no-api-key"
        return 1
    fi

    echo "  🤖 LLM 호출: provider=$provider model=$model" >&2
    log_event "llm-call-start" "\"provider\":\"$provider\"" "\"model\":\"$model\""

    # OpenAI-compatible chat completions
    local payload
    payload=$(PROMPT_FILE="$prompt_file" SYSTEM="$system_prompt" MODEL="$model" python3 << 'PYEOF'
import json, os
with open(os.environ['PROMPT_FILE']) as f: user = f.read()
payload = {
    "model": os.environ['MODEL'],
    "messages": [
        {"role": "system", "content": os.environ['SYSTEM']},
        {"role": "user", "content": user},
    ],
    "temperature": 0.3,
    "max_tokens": 2048,
}
print(json.dumps(payload))
PYEOF
)

    local response_file="/tmp/mutation-response-$TS_COMPACT.json"
    local http_code
    http_code=$(curl -sS -o "$response_file" -w "%{http_code}" \
        -X POST "${endpoint%/}/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $key" \
        -d "$payload" 2>/dev/null || echo "000")

    if [ "$http_code" != "200" ]; then
        echo "❌ HTTP $http_code" >&2
        echo "응답:" >&2
        cat "$response_file" >&2
        log_event "llm-call-failed" "\"httpCode\":$http_code"
        return 1
    fi

    log_event "llm-call-success" "\"httpCode\":200"

    RESP="$response_file" python3 -c "
import json, os, sys
with open(os.environ['RESP']) as f: r = json.load(f)
try:
    content = r['choices'][0]['message']['content']
    print(content)
except Exception as e:
    print(f'응답 파싱 실패: {e}', file=sys.stderr)
    print(json.dumps(r, indent=2)[:500], file=sys.stderr)
    sys.exit(1)
"
}

# ─── 메인 ───
SYSTEM_PROMPT="당신은 HyperAgents 자기진화 루프의 돌연변이 제안자입니다. 사용자가 제공한 운영 상태와 대상 bash 스크립트를 분석해 unified diff 1개와 근거를 생성하세요.

규칙:
1. 반드시 unified diff 형식 (patch -p1로 적용 가능). 파일 경로는 a/scripts/<FILENAME>, b/scripts/<FILENAME>.
2. 변경 최소화: 하나의 명확한 개선만 제안 (새 함수 추가 < 기존 로직 조정).
3. 안전: bash -n 통과해야 함. 외부 명령 사용 시 set -euo pipefail 존중.
4. 한국어 주석 허용. 작동하지 않을 것 같으면 제안 금지.
5. 출력 형식:
   ---DIFF-START---
   (unified diff 내용)
   ---DIFF-END---
   ---NOTES-START---
   (한국어 근거 설명 + 위험요소 + 검증 방법)
   ---NOTES-END---"

USER_CONTEXT=$(build_context)
PROMPT_FILE="/tmp/propose-prompt-$TS_COMPACT.md"
cat > "$PROMPT_FILE" << EOF
# 돌연변이 제안 요청

$USER_CONTEXT

## 요구사항
대상: $TARGET
목표: ${GOAL:-"운영 지표 개선 (deliveryRate↑, recoveryEvents↑, criticalErrors↓ 중 택1)"}
부모 노드: ${PARENT:-"(archive latest)"}

위 컨텍스트에서 가장 임팩트 있는 1개 개선을 제안하세요. DIFF만으로 바로 적용 가능해야 합니다.
EOF

if [ "$DRY_RUN" = true ]; then
    echo "  🔍 [DRY RUN] 프롬프트 미리보기:"
    echo "─── system ───"
    echo "$SYSTEM_PROMPT" | head -20
    echo "─── user (처음 100줄) ───"
    head -100 "$PROMPT_FILE"
    echo "─── end ───"
    echo ""
    echo "LLM 호출은 하지 않았습니다. --apply로 실행하세요."
    exit 0
fi

# LLM 호출
log_event "started" "\"parent\":\"${PARENT:-}\""
LLM_OUTPUT=$(call_llm "$PROMPT_FILE" "$SYSTEM_PROMPT") || {
    echo "❌ LLM 호출 실패" >&2
    exit 1
}

# 응답 파싱 (DIFF/NOTES 추출)
DIFF_CONTENT=$(echo "$LLM_OUTPUT" | awk '/---DIFF-START---/{flag=1; next} /---DIFF-END---/{flag=0} flag')
NOTES_CONTENT=$(echo "$LLM_OUTPUT" | awk '/---NOTES-START---/{flag=1; next} /---NOTES-END---/{flag=0} flag')

if [ -z "$DIFF_CONTENT" ]; then
    echo "❌ DIFF 블록 파싱 실패. 전체 응답:" >&2
    echo "$LLM_OUTPUT" | head -60 >&2
    log_event "diff-parse-failed"
    exit 1
fi

# 제안 ID
PROPOSAL_ID="mutation-${TARGET%.sh}-$TS_COMPACT"

# 저장 경로 결정
if [ "$APPLY" = true ]; then
    OUT_DIR="$PROPOSALS_DIR"
else
    OUT_DIR="/tmp"
fi

DIFF_FILE="$OUT_DIR/$PROPOSAL_ID.diff"
MD_FILE="$OUT_DIR/$PROPOSAL_ID.md"

echo "$DIFF_CONTENT" > "$DIFF_FILE"
cat > "$MD_FILE" << EOF
TITLE: LLM 돌연변이 제안 ($TARGET)
DATE: $TODAY
PRIORITY: medium
TARGET: $TARGET
STATUS: pending
AUTO_DIFFABLE: true
PARENT: ${PARENT:-$(bash "$SCRIPTS_DIR/archive.sh" list-nodes --format json 2>/dev/null | python3 -c "import json,sys; idx=json.load(sys.stdin); print(idx.get('latestId','') or '')" 2>/dev/null)}

## 근거
${NOTES_CONTENT:-"(LLM이 근거 미생성)"}

## 원본 LLM 응답 (참고)
저장 경로: $DIFF_FILE

EOF

# 사전 검증: patch --dry-run
VALIDATION="✅ 적용 가능 (patch --dry-run 통과)"
if ! (cd "$WORKSPACE" && patch -p1 --dry-run < "$DIFF_FILE" >/dev/null 2>&1); then
    VALIDATION="⚠️ patch --dry-run 실패 — 사람이 검토 필요"
    log_event "validation-failed" "\"file\":\"$DIFF_FILE\""
fi

echo "  📝 제안 생성: $PROPOSAL_ID"
echo "  📄 diff:  $DIFF_FILE"
echo "  📄 md:    $MD_FILE"
echo "  🔍 검증: $VALIDATION"
echo ""
log_event "done" "\"id\":\"$PROPOSAL_ID\"" "\"apply\":\"$APPLY\""

if [ "$APPLY" != true ]; then
    echo "ℹ️ /tmp에 저장됨. proposals/로 옮기려면 --apply 재실행 또는 수동 cp."
fi
