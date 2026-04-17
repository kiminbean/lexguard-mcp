TITLE: LLM 돌연변이 제안 (notify-hyperagent.sh)
DATE: 2026-04-18
PRIORITY: medium
TARGET: notify-hyperagent.sh
STATUS: pending
AUTO_DIFFABLE: true
PARENT: 0001

## 근거
이 변경 사항은 `send_telegram` 함수에 재시도 로직을 추가하여, 429 또는 5xx 응답이 발생할 경우 최대 3회까지 재시도하도록 합니다. 각 재시도 사이에는 5초의 지연을 두어 서버에 부담을 줄입니다. 이를 통해 일시적인 네트워크 문제나 서버 과부하로 인한 실패를 극복할 수 있습니다. 

위험 요소로는 무한 루프에 빠질 가능성이 있으나, 최대 재시도 횟수를 설정하여 이를 방지했습니다. 검증 방법으로는 스크립트를 실행하여 의도적으로 실패를 유도한 후, 재시도 로직이 정상 작동하는지 확인할 수 있습니다.

## 원본 LLM 응답 (참고)
저장 경로: /Users/ibkim/Projects/openclaw/memory/proposals/mutation-notify-hyperagent-20260418_063645.diff

