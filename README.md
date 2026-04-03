[![MCP Badge](https://lobehub.com/badge/mcp-full/seonaru-lexguard-mcp)](https://lobehub.com/mcp/seonaru-lexguard-mcp)
![Python](https://img.shields.io/badge/Python-3.11%2B-blue)
![FastAPI](https://img.shields.io/badge/FastAPI-0.104%2B-green)
![License](https://img.shields.io/badge/License-MIT-yellow)
![CI](https://github.com/SeoNaRu/lexguard-mcp/actions/workflows/ci.yml/badge.svg)

# ⚖️ LexGuard MCP (법실마리)

> **한국 법령·판례·법령해석을 AI가 이해하기 쉬운 형태로 연결하는 MCP 서버**
>
> 국가법령정보센터(Open Law) 공식 데이터를 기반으로, 법령·조문·판례·법령해석·행정심판·헌재결정을 **하나의 질문 흐름**으로 제공합니다.

- **MCP Endpoint**: [https://lexguard-mcp.onrender.com/mcp](https://lexguard-mcp.onrender.com/mcp)
- **Health Check**: [https://lexguard-mcp.onrender.com/health](https://lexguard-mcp.onrender.com/health)
- **GitHub**: [https://github.com/SeoNaRu/lexguard-mcp](https://github.com/SeoNaRu/lexguard-mcp)

---

## Why LexGuard?

법은 필요할 때마다 멀고 어렵게 느껴집니다.
높은 비용, 낯선 용어, 어디서부터 찾아야 할지 모르는 구조.

**LexGuard MCP(법실마리)** 는 이 문제에서 출발했습니다.

- 사용자는 **사람의 말**로 질문하고
- AI는 질문 의도를 분석한 뒤
- **공식 법령·판례 데이터**를 근거로 실마리를 제공합니다.

> 판단이나 법률 자문을 대신하지 않습니다.
> 다만, _법을 처음 마주하는 순간을 덜 어렵게_ 만드는 것을 목표로 합니다.

---

## Core Features

| 기능 | 설명 |
|------|------|
| **통합 법률 QA** | 법령·판례·법령해석·행정심판·헌재결정 병렬 종합 탐색 |
| **조문 정밀 조회** | 법령명 + 조문번호로 특정 조항 직접 조회 |
| **문서·계약서 분석** | 계약서·약관 붙여넣기만으로 조항별 법적 이슈 자동 감지 |
| **판례 번호 직접 감지** | `2023다12345`, `2021헌마123` 형식 자동 인식 후 즉시 검색 |
| **도메인 자동 분류** | 노동·개인정보·부동산·소비자·세금·금융 등 10개 법률 도메인 |
| **자연어 시간 조건** | "최근 3년", "2023년 이후" 등 자연어 시간 표현 자동 파싱 |
| **Reranker 파이프라인** | 검색 결과를 쿼리 적합도(BM25 + Keyword Hybrid) 기준으로 재정렬 |
| **병렬 검색** | `asyncio.gather` 기반 멀티 API 동시 호출로 응답 속도 최소화 |
| **Rate Limiting** | IP당 60 req/min 제한으로 남용 방지 |

---

## MCP Tools

### `legal_qa_tool` — 범용 법률 QA

모든 법률 질문의 단일 진입점입니다. 질문 하나로 법령·판례·해석·위원회 결정례를 병렬 탐색하고 종합합니다.

**Capabilities**

- 10개 도메인 자동 분류
- 질문 의도(Intent) 다중 감지 및 우선순위 정렬
- 법령 → 판례 → 해석 → 위원회 병렬 탐색
- 자연어 시간 조건 필터링 (`date_from` / `date_to` 자동 변환)

**Input Schema**

| 파라미터 | 타입 | 필수 | 설명 |
|---------|------|------|------|
| `query` | string | ✅ | 사용자의 법률 질문 |
| `max_results_per_type` | integer | — | 타입당 최대 결과 수 (기본값: 3, 최대: 10) |

**Example Prompts**

```
프리랜서인데 근로자성 인정된 판례 있나요?
최근 3년 부당해고 판례 알려줘
개인정보 유출됐는데 법적으로 어떻게 되나요?
2023다12345 판례 찾아줘
```

---

### `law_article_tool` — 법령 조문 정밀 조회

법령명과 조문번호를 알고 있을 때 특정 조항을 직접 조회합니다. `legal_qa_tool`이 "탐색"이라면, 이 툴은 "정확한 조회"입니다.

**Input Schema**

| 파라미터 | 타입 | 필수 | 설명 |
|---------|------|------|------|
| `law_name` | string | ✅ | 법령명 (예: 근로기준법, 민법) |
| `article_number` | string | — | 조문 번호 (예: `50`, `2`). 생략 시 법령 개요 반환 |
| `hang` | string | — | 항 번호 (예: `1`, `2`) |
| `ho` | string | — | 호 번호 (예: `1`, `2`) |
| `mok` | string | — | 목 번호 (예: `가`, `나`) |

**Example Prompts**

```
근로기준법 제50조 내용 알려줘
민법 제750조 3항이 뭐야?
개인정보보호법 제17조
```

---

### `document_issue_tool` — 계약서·약관 분석

문서를 붙여넣으면 조항 단위로 법적 이슈를 추출하고, 관련 법령·판례를 자동 검색합니다.

**Input Schema**

| 파라미터 | 타입 | 필수 | 설명 |
|---------|------|------|------|
| `document_text` | string | ✅ | 계약서·약관 전문 |
| `auto_search` | boolean | — | 조항별 자동 법령 검색 여부 (기본값: true) |
| `max_clauses` | integer | — | 분석할 최대 조항 수 (기본값: 3) |
| `max_results_per_type` | integer | — | 타입당 최대 결과 수 (기본값: 3) |

**Supported Document Types**

- `labor` — 근로계약서 / 용역계약서
- `lease` — 임대차 계약서
- `terms` — 이용약관

**Example Prompts**

```
이 프리랜서 계약서 문제 있는지 봐줘
아래 임대차 계약서에서 불리한 조항 찾아줘
```

---

### `health` — 서버 상태 확인

MCP 서버 동작 여부, API Key 설정 상태, 환경 변수를 확인합니다.

---

## MCP Prompts

`prompts/list` 및 `prompts/get` 엔드포인트를 지원합니다.

| Prompt 이름 | 설명 |
|-------------|------|
| `legal_basis_answer` | 관련 법령 조문 번호와 판례 요지를 포함한 답변 요청 |
| `precedent_summary` | 판례를 사실관계 / 쟁점 / 판단요지로 요약 |
| `contract_risk_check` | 계약서에서 법적 위험 조항 항목별 정리 |
| `legal_qa` | 특정 상황에 대한 법률적 관점 설명 |

---

## MCP Resources

`resources/list` 및 `resources/read` 엔드포인트를 지원합니다.

### URI Scheme

| 형식 | 설명 | 예시 |
|------|------|------|
| `law://{법령명}` | 법령 본문 조회 | `law://근로기준법` |
| `case://{검색어}` | 판례 검색 (상위 5건) | `case://부당해고` |
| `interpret://{검색어}` | 법령해석 검색 (상위 5건) | `interpret://근로자성` |

### Featured Resources (기본 제공)

근로기준법, 민법, 형법, 개인정보보호법, 상법, 국가공무원법, 행정소송법 등 주요 법령을 즉시 조회할 수 있습니다.

---

## Installation

### Method 1. Local (Python)

```bash
git clone https://github.com/SeoNaRu/lexguard-mcp
cd lexguard-mcp
pip install -r requirements.txt
cp .env.example .env   # LAW_API_KEY 설정
python -m src.main
```

### Method 2. Docker

```bash
docker build -t lexguard-mcp .
docker run -p 8099:8099 -e LAW_API_KEY=your_key lexguard-mcp
```

### Method 3. Remote MCP (One-click)

**Claude Desktop** (`claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "lexguard-mcp": {
      "url": "https://lexguard-mcp.onrender.com/mcp"
    }
  }
}
```

**Cursor** (`.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "lexguard-mcp": {
      "url": "https://lexguard-mcp.onrender.com/mcp"
    }
  }
}
```

### API Key 발급

국가법령정보센터 Open API 키가 필요합니다.

1. [https://open.law.go.kr](https://open.law.go.kr) 회원가입
2. API 활용 신청
3. `.env`에 `LAW_API_KEY=발급받은키` 설정

---

## Architecture

```
Client (Cursor / Claude)
    │ JSON-RPC 2.0 over SSE
    ▼
FastAPI  (/mcp POST)
    │ Rate Limiting (slowapi, 60 req/min/IP)
    ▼
MCP Routes  (tools/call · prompts/get · resources/read)
    │
    ▼
Services  (SmartSearchService · SituationGuidanceService)
    │ asyncio.gather (병렬 멀티 API 호출)
    ▼
Repositories  (Law · Precedent · Interpretation · Appeal · Constitutional …)
    │ httpx (동기/비동기 HTTP 클라이언트)
    │ TTLCache (검색 결과 30분 / 실패 5분)
    │ Exponential Backoff Retry
    ▼
국가법령정보센터 DRF API  (172개 엔드포인트)
```

**검색 파이프라인**

```
질문 입력
    → 판례 번호 패턴 조기 감지 (2023다12345 / 2021헌마123)
    → 도메인 분류 + 의도(Intent) 분석
    → 시간 조건 파싱
    → asyncio.gather 병렬 API 호출
    → Reranker (BM25 + Keyword Hybrid 재정렬)
    → 응답 포매팅
```

**주요 기술 스택**

| 구분 | 사용 기술 |
|------|-----------|
| Web Framework | FastAPI + Uvicorn |
| MCP Transport | Streamable HTTP (SSE) |
| HTTP Client | httpx (sync + async) |
| Cache | cachetools TTLCache |
| Rate Limiting | slowapi |
| Search Ranking | BM25 + Keyword Hybrid Reranker |
| CI/CD | GitHub Actions (Python 3.11 / 3.12) |
| Testing | pytest + pytest-asyncio |

---

## Development

```bash
# 테스트 실행
pytest tests/ -v

# 린트
ruff check src/

# 로컬 서버 (자동 재로드)
RELOAD=true python -m src.main
```

---

## License

MIT License — 자유롭게 사용하되 출처를 표기해주세요.

---

## Contribution

Issues & PRs are always welcome.
법률 도메인 데이터, 검색 품질 개선, 새로운 MCP 툴 아이디어 모두 환영합니다.

---

> **LexGuard MCP — 법률 정보의 실마리를 찾아드립니다.**
> 법은 어렵지만, 첫 실마리는 쉬워질 수 있습니다.
