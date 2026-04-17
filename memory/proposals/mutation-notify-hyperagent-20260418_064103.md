TITLE: LLM 돌연변이 제안 (notify-hyperagent.sh)
DATE: 2026-04-18
PRIORITY: medium
TARGET: notify-hyperagent.sh
STATUS: pending
AUTO_DIFFABLE: true
PARENT: 0001

## 근거
**근거**: 현재 전달률이 84.2%로 100%에 미달합니다. Telegram API는 429(요청제한)·5xx(서버일시장애)를 빈번히 반환하며, 이 경우 단순히 실패 처리하고 있습니다. 지수 백오프(1→2→4초) 최대 3회 재시도를 추가하면 일시적 오류를 자연스럽게 흡수하여 전달률을 90%+로 끌어올릴 수 있습니다. `send_telegram()` 함수 내부만 변경하므로 영향 범위가 최소입니다.

**위험요소**:
- 429 응답 시 `Retry-After` 헤더를 무시하고 고정 지수 백오프를 사용 → 극단적 rate-limit 상황에서 봇이 일시 차단될 가능성(낮음, 최대 3회·총 7초 대기)
- `sleep` 호출로 최악의 경우 7초 추가 지연

**검증 방법**:
1. `bash

## 원본 LLM 응답 (참고)
저장 경로: /Users/ibkim/Projects/openclaw/memory/proposals/mutation-notify-hyperagent-20260418_064103.diff

