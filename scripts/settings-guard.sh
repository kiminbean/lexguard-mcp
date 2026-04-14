#!/bin/bash
# settings-guard.sh — 설정 보호 가드
# 업데이트 전후에 설정 무결성 확인 및 복원
# 사용: settings-guard.sh [backup|verify|restore|diff]

set -euo pipefail

CONFIG="$HOME/.openclaw/openclaw.json"
BACKUP_DIR="$HOME/Projects/openclaw/scripts/backup"
CRITICAL_KEYS_FILE="$BACKUP_DIR/critical-keys.json"
LOG="$HOME/Projects/openclaw/memory/settings-guard.log"
TODAY=$(date '+%Y-%m-%d')

mkdir -p "$BACKUP_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

# ─── 보호할 핵심 설정 정의 ───
generate_critical_keys() {
    cat > "$CRITICAL_KEYS_FILE" << 'EOF'
{
  "version": "1.0",
  "description": "OpenClaw 핵심 설정 — 업데이트 후 반드시 확인",
  "checks": [
    {
      "path": "tools.exec.security",
      "expected": "full",
      "critical": true,
      "description": "exec 전체 권한"
    },
    {
      "path": "agents.defaults.model.primary",
      "expected": "zai/glm-5.1",
      "critical": true,
      "description": "기본 모델"
    },
    {
      "path": "agents.defaults.imageModel.primary",
      "expected": "google/gemini-3-pro-preview",
      "critical": true,
      "description": "이미지 모델"
    },
    {
      "path": "agents.defaults.memorySearch.provider",
      "expected": "openai",
      "critical": true,
      "description": "메모리 검색 프로바이더"
    },
    {
      "path": "agents.defaults.memorySearch.enabled",
      "expected": true,
      "critical": true,
      "description": "메모리 검색 활성화"
    },
    {
      "path": "agents.defaults.heartbeat.every",
      "expected": "1h",
      "critical": false,
      "description": "하트비트 주기"
    },
    {
      "path": "channels.telegram.enabled",
      "expected": true,
      "critical": true,
      "description": "Telegram 활성화"
    },
    {
      "path": "channels.telegram.allowFrom",
      "expected_contains": "8137155160",
      "critical": true,
      "description": "Telegram 허용 발신자"
    },
    {
      "path": "plugins.slots.memory",
      "expected": "memory-core",
      "critical": true,
      "description": "메모리 슬롯"
    },
    {
      "path": "agents.defaults.workspace",
      "expected": "/Users/ibkim/Projects/openclaw",
      "critical": true,
      "description": "워크스페이스 경로"
    }
  ],
  "protected_files": [
    {"path": "AGENTS.md", "description": "에이전트 규칙 (진화 엔진 영유지)"},
    {"path": "MEMORY.md", "description": "장기 기억"},
    {"path": "HEARTBEAT.md", "description": "하트비트 루틴"},
    {"path": "SOUL.md", "description": "에이전트 성격"},
    {"path": "USER.md", "description": "사용자 프로필"},
    {"path": "TOOLS.md", "description": "도구 설정"},
    {"path": "scripts/evolve.sh", "description": "진화 엔진"},
    {"path": "scripts/metacognitive.sh", "description": "메타인지 엔진"},
    {"path": "scripts/self-modify.sh", "description": "자기수정 루프"},
    {"path": "scripts/auto-skill.sh", "description": "자동 스킬 생성"},
    {"path": "scripts/cron-audit.sh", "description": "크론잡 감사"},
    {"path": "scripts/prediction-tracker.sh", "description": "예측 추적"},
    {"path": "scripts/settings-guard.sh", "description": "설정 보호 가드"},
    {"path": "scripts/hyperagents-restore.sh", "description": "HyperAgents 자동 복구"},
    {"path": "memory/failure-patterns.md", "description": "실패 패턴 DB"},
    {"path": "memory/learning-state.json", "description": "학습 상태"},
    {"path": "memory/evolution-log.md", "description": "진화 로그"},
    {"path": "memory/metacognitive-log.md", "description": "메타인지 로그"}
  ]
}
EOF
}

# ─── 백업 ───
backup() {
    echo "📦 설정 백업..."
    generate_critical_keys
    
    # 설정 파일 백업
    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$BACKUP_DIR/openclaw.json.$TODAY"
        echo "  ✅ openclaw.json 백업 완료"
    fi
    
    # 워크스페이스 핵심 파일 백업
    for f in AGENTS.md MEMORY.md HEARTBEAT.md SOUL.md USER.md TOOLS.md; do
        if [ -f "$HOME/Projects/openclaw/$f" ]; then
            cp "$HOME/Projects/openclaw/$f" "$BACKUP_DIR/$f.bak"
        fi
    done
    
    # 스크립트 백업
    mkdir -p "$BACKUP_DIR/scripts"
    for f in evolve.sh auto-skill.sh cron-audit.sh prediction-tracker.sh settings-guard.sh; do
        if [ -f "$HOME/Projects/openclaw/scripts/$f" ]; then
            cp "$HOME/Projects/openclaw/scripts/$f" "$BACKUP_DIR/scripts/$f.bak"
        fi
    done
    
    # 메모리 백업
    mkdir -p "$BACKUP_DIR/memory"
    for f in failure-patterns.md learning-state.json evolution-log.md; do
        if [ -f "$HOME/Projects/openclaw/memory/$f" ]; then
            cp "$HOME/Projects/openclaw/memory/$f" "$BACKUP_DIR/memory/$f.bak"
        fi
    done
    
    log "BACKUP: 전체 백업 완료"
    echo "  ✅ 백업 완료 ($BACKUP_DIR)"
}

# ─── 검증 ───
verify() {
    echo "🔍 설정 무결성 검증..."
    generate_critical_keys
    
    if [ ! -f "$CONFIG" ]; then
        echo "  ❌ CRITICAL: openclaw.json 없음!"
        log "VERIFY_FAIL: openclaw.json 없음"
        return 1
    fi
    
    python3 << PYEOF
import json, sys

config_path = "$CONFIG"
keys_path = "$CRITICAL_KEYS_FILE"

with open(config_path) as f:
    config = json.load(f)

with open(keys_path) as f:
    keys = json.load(f)

issues = []
passed = 0

for check in keys['checks']:
    path = check['path']
    parts = path.split('.')
    expected = check.get('expected', check.get('expected_contains', None))
    critical = check['critical']
    
    # 중첩 경로 탐색
    obj = config
    for p in parts:
        if isinstance(obj, dict) and p in obj:
            obj = obj[p]
        else:
            obj = None
            break
    
    # contains 체크
    if 'expected_contains' in check:
        if isinstance(obj, list) and check['expected_contains'] in obj:
            passed += 1
            continue
        else:
            issues.append(f"{'🔴' if critical else '🟡'} {check['description']}: '{path}' = {obj} (필요: {check['expected_contains']} 포함)")
            continue
    
    if obj == expected:
        passed += 1
    else:
        issues.append(f"{'🔴' if critical else '🟡'} {check['description']}: '{path}' = {obj} (기대: {expected})")

# 보호 파일 확인
import os
workspace = "$HOME/Projects/openclaw"
for pf in keys['protected_files']:
    fpath = os.path.join(workspace, pf['path'])
    if not os.path.exists(fpath):
        issues.append(f"🔴 {pf['description']}: '{pf['path']}' 파일 없음!")
    else:
        passed += 1

print(f"\n  📊 검증 결과: {passed}/{passed + len(issues)} 통과")

if issues:
    print(f"\n  ⚠️ 문제 발견 ({len(issues)}개):")
    for i in issues:
        print(f"    {i}")
    sys.exit(1)
else:
    print(f"  ✅ 모든 설정 정상!")
    sys.exit(0)
PYEOF
    
    if [ $? -eq 0 ]; then
        log "VERIFY_PASS: 모든 설정 정상"
    else
        log "VERIFY_FAIL: 설정 문제 발견"
    fi
}

# ─── 복원 ───
restore() {
    echo "♻️ 설정 복원..."
    
    # 가장 최근 백업 찾기
    LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/openclaw.json.* 2>/dev/null | head -1)
    
    if [ -n "$LATEST_BACKUP" ]; then
        cp "$LATEST_BACKUP" "$CONFIG"
        echo "  ✅ openclaw.json 복원 완료 (from $(basename "$LATEST_BACKUP"))"
        log "RESTORE: openclaw.json 복원"
    else
        echo "  ⚠️ 백업 파일 없음"
    fi
    
    # 워크스페이스 파일 복원
    for f in AGENTS.md MEMORY.md HEARTBEAT.md SOUL.md USER.md TOOLS.md; do
        if [ ! -f "$HOME/Projects/openclaw/$f" ] && [ -f "$BACKUP_DIR/$f.bak" ]; then
            cp "$BACKUP_DIR/$f.bak" "$HOME/Projects/openclaw/$f"
            echo "  ✅ $f 복원"
        fi
    done
    
    # 스크립트 복원
    for f in evolve.sh auto-skill.sh cron-audit.sh prediction-tracker.sh settings-guard.sh; do
        if [ ! -f "$HOME/Projects/openclaw/scripts/$f" ] && [ -f "$BACKUP_DIR/scripts/$f.bak" ]; then
            mkdir -p "$HOME/Projects/openclaw/scripts"
            cp "$BACKUP_DIR/scripts/$f.bak" "$HOME/Projects/openclaw/scripts/$f"
            chmod +x "$HOME/Projects/openclaw/scripts/$f"
            echo "  ✅ scripts/$f 복원"
        fi
    done
    
    # 메모리 복원
    for f in failure-patterns.md learning-state.json evolution-log.md; do
        if [ ! -f "$HOME/Projects/openclaw/memory/$f" ] && [ -f "$BACKUP_DIR/memory/$f.bak" ]; then
            mkdir -p "$HOME/Projects/openclaw/memory"
            cp "$BACKUP_DIR/memory/$f.bak" "$HOME/Projects/openclaw/memory/$f"
            echo "  ✅ memory/$f 복원"
        fi
    done
    
    log "RESTORE: 복원 완료"
    echo ""
    echo "  ⚠️ 복원 후 Gateway 재시작 필요: openclaw gateway restart"
}

# ─── 차이 비교 ───
diff_config() {
    echo "📋 현재 설정 vs 기대 설정"
    generate_critical_keys
    
    python3 << PYEOF
import json

config_path = "$CONFIG"
keys_path = "$CRITICAL_KEYS_FILE"

with open(config_path) as f:
    config = json.load(f)

with open(keys_path) as f:
    keys = json.load(f)

print(f"{'키':<50} {'현재':<30} {'기대':<30} {'상태'}")
print("─" * 130)

for check in keys['checks']:
    path = check['path']
    parts = path.split('.')
    expected = check.get('expected', check.get('expected_contains', '?'))
    
    obj = config
    for p in parts:
        if isinstance(obj, dict) and p in obj:
            obj = obj[p]
        else:
            obj = None
            break
    
    status = "✅" if obj == expected else ("⚠️" if 'expected_contains' in check and isinstance(obj, list) and check['expected_contains'] in str(obj) else "❌")
    current = str(obj)[:28] if obj is not None else "None"
    print(f"{path:<50} {current:<30} {str(expected)[:28]:<30} {status}")
PYEOF
}

# ─── 메인 ───
case "${1:-verify}" in
    backup) backup ;;
    verify) verify ;;
    restore) restore ;;
    diff) diff_config ;;
    *)
        echo "Usage: settings-guard.sh [backup|verify|restore|diff]"
        echo "  backup  — 모든 설정+워크스페이스 파일 백업"
        echo "  verify  — 설정 무결성 검증"
        echo "  restore — 백업에서 복원"
        echo "  diff    — 현재 vs 기대 설정 비교"
        ;;
esac
