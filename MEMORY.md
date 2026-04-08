# MEMORY.md — 장기 기억

_중요한 결정, 인사이트, 교훈, 선호도를 기록한다. 정기적으로 검토하고 갱신한다._

---

## 👤 사용자 정보
- **이름**: 기수 김
- **이메일**: kiminbean@gmail.com
- **시간대**: Asia/Seoul
- **관심사**: AI/에이전트, OpenClaw, LexGuard, 코딩 자동화, 스타트업
- **프로젝트**: LexGuard MCP, MoltGram, OpenClaw 에이전트

## 🔧 시스템 설정
- **호스트**: IB의 Mac mini (Apple Silicon)
- **기본 모델**: zai/glm-5.1 (GLM-5V-Turbo는 Coding Plan에서 아직 접근 불가)
- **이미지 모델**: google/gemini-3-pro-preview
- **채널**: Telegram (@shumi_moltbot_bot)
- **exec 보안**: full (openclaw.json + exec-approvals.json 통일)
- **Telegram 봇**: @shumi_moltbot_bot

## 📡 Tech/AI 트렌드 인사이트

### 2026-04-06: GeekNews 인기 글에서 얻은 인사이트
- **LLM 지식 관리 패러다임 전환**: RAG(재검색) → 누적형 지식 저장소(축적). Andrej Karpathy의 LLM-Wiki 제안
- **토큰 최적화 트렌드**: rtk(CLI 프록시), Caveman(원시인 말투) 등 출력 토큰 절감 도구 등장. 60~90% 절감
- **온디바이스 AI**: Mac mini에서 Ollama + Gemma 4 26B 로컬 실행. Apple Silicon 활용
- **AI 코딩 생산성**: 8년 프로젝트를 3개월로 단축. 공식 문법 명세 부재 문제를 AI로 해결
- **코딩 에이전트 아키텍처**: LLM 중심 코드 작성-실행-피드백 루프. 에이전트 하니스의 중요성
- **개발팀 속도**: 진짜 병목은 사람이 아니라 코드베이스 Drag. 대시보드에 드러나지 않음
- **AI 연구 위기**: 이해 없이 결과만 생산하는 연구자 증가. 위기는 기술이 아닌 인간의 학습 과정
- **디자인 시스템 AI화**: DESIGN.MD 개념. AI 에이전트가 읽고 일관된 UI 생성

### 2026-04-06: LiteLLM 공급망 공격
- LiteLLM v1.82.7/1.82.8에 백도어 삽입 (PyPI)
- 공격 경로: Trivy 보안 스캐너 CI/CD 해킹 → maintainer PyPI 자격증명 탈취
- **교훈**: Python 패키지 공급망 보안 중요성. 정기 버전 확인 필요

## 🔑 중요 결정 기록
- **2026-04-05**: GLM-5V-Turbo를 기본 모델로 설정했으나 Coding Plan에서 접근 불가 → glm-5.1로 fallback
- **2026-04-05**: Z.AI 지원에 GLM-5V-Turbo 접근 요청 이메일 발송 (support@z.ai)
- **2026-04-05**: exec 보안을 full로 영구 설정. openclaw.json + exec-approvals.json 통일
- **2026-04-06**: 날씨 스킬 바람 단위를 m/s로 오버라이드

## 🛠️ 도구/스킬 노트
- **날씨 스킬**: `~/.openclaw/skills/weather/SKILL.md` 로컬 오버라이드. 바람 m/s 필수
- **Moltbook 트위터**: 가입 시 트위터 정보 정확히 확인 안 됨. kiminbean@gmail.com으로 가입
- **LexGuard MCP**: 국가법령정보센터 타법개정 MST는 eflawjosub에서 조문 미지원 → Playwright fallback 필요

## ⚠️ 실패 패턴 & 교훈
- `config.patch` 후에도 재시작 시 설정 유지 확인 필요
- 크론잡 연속 에러 시 즉시 비활성화
- Gateway 블로킹: 긴 타임아웃 크론잡이 메인 세션 방해
- Python venv 심볼릭 링크 끊어짐 주의 (버전 업그레이드 후)
