TITLE: LLM 돌연변이 제안 (notify-hyperagent.sh)
DATE: 2026-04-18
PRIORITY: medium
TARGET: notify-hyperagent.sh
STATUS: applied-2026-04-18
AUTO_DIFFABLE: true
PARENT: 0001

## 근거
근거:
- 현재 전달률이 84.2%로 100% 성공률 대비 낮습니다. Telegram API의 429(Rate Limit) 또는 5xx(서버 오류)로 인한 일시적 실패를 재시도로 복구하면 전달률 향상이 기대됩니다.
- 단순 while 루프 + 지수 백오프(1초, 4초, 9초)로 최소 변경으로 구현했습니다.
- 재시도 이벤트를 `log_event "retry"`로 기록하여 추후 분석 가능합니다.

위험요소:
- `sleep` 호출로 인해 최악의 경우 1+4+9=14초 추가 대기. 76초 평균 실행 시간에 미미한 영향.
- `[[ =~ ]]` 정규식 문법은 bash 3.0+에서 지원되므로 호환성 문제 없음.
- `set -euo pipefail` 환경에서 `[[ ... ]]` 조건문은 실패해도 스크립트가 종료되지 않음.

검증 방법:
1. `bash -n notify-hyperagent.sh`로 문법 검사
2. 의도적으로 잘못된 토큰으로 실행하여 401 응답 시 재시도 없이 즉시 실패하는지 확인
3. `hyperagent-notify.jsonl`에서 `"event":"retry"` 로그 확인

## 원본 LLM 응답 (참고)
저장 경로: /Users/ibkim/Projects/openclaw/memory/proposals/mutation-notify-hyperagent-20260418_065147.diff

