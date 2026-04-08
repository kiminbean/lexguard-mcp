# 실패 패턴 데이터베이스

> 작업 중 발생한 오류, 원인, 해결책을 기록하여 동일 실수 반복 방지

## 🔴 Critical (시스템 장애급)

### 2026-03-30: memory-lancedb + Homebrew Cellar 충돌
- **오류**: `@lancedb/lancedb` npm 설치 시 Cellar node_modules 구조 변경 → 모든 플러그인 런타임 해석 실패
- **원인**: Homebrew Cellar는 read-only 영역, npm install이 구조를 망가뜨림
- **해결**: `brew reinstall`로 복원
- **규칙**: ❌ `/opt/homebrew/Cellar/openclaw-cli/` 내부에 `npm install` 절대 금지

### 2026-03-30: 게이트웨이 동결 - Telegram 크래시 루프
- **오류**: `Unable to resolve plugin runtime module` 무한 크래시 루프
- **원인**: Homebrew 빌드에서 `dist/docs/` 디렉토리 누락 → heartbeat/cron 템플릿 해석 실패
- **해결**: `brew reinstall` + `dist/docs → docs` 심볼릭 링크
- **규칙**: 업데이트 후 `openclaw health`로 Telegram 상태 필수 확인

## 🟡 Warning (기능 제한급)

### 2026-03-30: expect-cli ioreg 샌드박스 이슈
- **오류**: `ioreg: command not found` → expect-cli 크래시
- **원인**: OpenClaw 샌드박스 PATH에 `/usr/sbin/` 없음
- **해결**: expect-cli 번들에서 `ioreg` → `/usr/sbin/ioreg` 절대 경로 패치
- **규칙**: expect-cli 업데이트 시 재패치 필수

### 2026-03-31: 국가법령정보센터 API IP 미등록
- **오류**: "사용자 정보 검증에 실패하였습니다"
- **원인**: Open API 호출 시 서버 IP 사전 등록 필수
- **해결**: open.law.go.kr에서 IP 등록 후 승인 대기
- **규칙**: 외부 API 연동 시 IP 인증 필요 여부 먼저 확인

### 2026-04-02: Telegram exec approvals /approve 미작동
- **오류**: "Telegram exec approvals are not enabled for this bot account"
- **원인**: openclaw.json에 execApprovals 설정 추가했으나 /approve 명령 인식 안 됨
- **해결**: 진행 중 — 추가 조사 필요
- **규칙**: exec 승인 설정 시 공식 문서 확인 우선

## 🟢 Info (경험 기록)

### 2026-04-02: DuckDuckGo 웹 검색 설정
- **문제**: Perplexity provider 비활성화로 web_search 작동 안 함
- **해결**: `tools.web.search.provider` → `"duckduckgo"` (API 키 불필요)
- **학습**: OpenClaw web_search provider 변경 시 gateway restart 필수

---

## 📊 실패 패턴 분석

| 패턴 | 횟수 | 주요 원인 |
|------|------|----------|
| Homebrew/Cellar 충돌 | 2 | Cellar read-only 영역에 npm install |
| PATH 누락 | 1 | 샌드박스 PATH에 시스템 경로 없음 |
| 외부 API 인증 | 1 | IP/키 등록 누락 |
| 플러그인 설정 불일치 | 2 | slots/allow/entries 불일치 |

### 반복 주의사항
1. **절대 금지**: `/opt/homebrew/Cellar/` 내부 npm install
2. **업데이트 후 필수**: `openclaw health`, 심볼릭 링크 확인
3. **외부 API 연동**: IP/도메인 등록 필요 여부 먼저 확인
4. **플러그인 설정**: allow + entries + slots 일관성 확인
