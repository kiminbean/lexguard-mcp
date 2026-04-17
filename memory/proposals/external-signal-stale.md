TARGET: evolve.sh
PRIORITY: medium
METRIC: 마지막 실패 기록 16일 전
DESCRIPTION: failure-patterns.md가 16일 정체. 입력 데이터 고갈 또는 실패 기록 습관 상실.
ACTION: 실패 발생 시 failure-patterns.md에 기록 훅 추가. heartbeat에 알림
EVIDENCE: lastFailureDate = 2026-04-02
DATE: 2026-04-18
STATUS: pending
AUTO_DIFFABLE: false
