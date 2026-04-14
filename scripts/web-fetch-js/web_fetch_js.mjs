#!/usr/bin/env node
/**
 * web_fetch_js.mjs — Playwright 기반 JS 렌더링 웹 스크래퍼
 *
 * SPA/React/Next.js 등 JavaScript 렌더링이 필요한 페이지에서
 * 텍스트/마크다운을 추출합니다. OpenClaw의 web_fetch 도구가
 * JS를 실행하지 못하는 것을 보완합니다.
 *
 * 사용법:
 *   node scripts/web_fetch_js.mjs <url> [옵션]
 *
 * 옵션:
 *   --wait <ms>       JS 렌더링 대기 시간 (기본: 2000)
 *   --timeout <ms>    전체 타임아웃 (기본: 30000)
 *   --format text|markdown  출력 형식 (기본: markdown)
 *   --selector <CSS>  추출할 DOM 요소 (기본: body)
 *   --max-chars <N>   최대 출력 문자수 (기본: 50000)
 *   --no-headless     헤드리스 모드 해제 (디버깅용)
 */

import { chromium } from "playwright";

// ─── CLI 파싱 ───────────────────────────────────────────────

function parseArgs(argv) {
  const args = {
    url: null,
    wait: 2000,
    timeout: 30000,
    format: "markdown",
    selector: "body",
    maxChars: 50000,
    headless: true,
  };

  let i = 2; // node, script skip
  while (i < argv.length) {
    const arg = argv[i];
    switch (arg) {
      case "--wait":
        args.wait = parseInt(argv[++i], 10) || 2000;
        break;
      case "--timeout":
        args.timeout = parseInt(argv[++i], 10) || 30000;
        break;
      case "--format":
        args.format = argv[++i] === "text" ? "text" : "markdown";
        break;
      case "--selector":
        args.selector = argv[++i] || "body";
        break;
      case "--max-chars":
        args.maxChars = parseInt(argv[++i], 10) || 50000;
        break;
      case "--no-headless":
        args.headless = false;
        break;
      default:
        if (!arg.startsWith("-") && !args.url) {
          args.url = arg;
        }
        break;
    }
    i++;
  }
  return args;
}

// ─── HTML → Markdown 변환 (pure JS, 의존성 없음) ───────────

function htmlToMarkdown(html) {
  let md = html;

  // 제목
  md = md.replace(/<h1[^>]*>(.*?)<\/h1>/gi, "# $1\n\n");
  md = md.replace(/<h2[^>]*>(.*?)<\/h2>/gi, "## $1\n\n");
  md = md.replace(/<h3[^>]*>(.*?)<\/h3>/gi, "### $1\n\n");
  md = md.replace(/<h4[^>]*>(.*?)<\/h4>/gi, "#### $1\n\n");
  md = md.replace(/<h5[^>]*>(.*?)<\/h5>/gi, "##### $1\n\n");
  md = md.replace(/<h6[^>]*>(.*?)<\/h6>/gi, "###### $1\n\n");

  // 강조
  md = md.replace(/<strong[^>]*>(.*?)<\/strong>/gi, "**$1**");
  md = md.replace(/<b[^>]*>(.*?)<\/b>/gi, "**$1**");
  md = md.replace(/<em[^>]*>(.*?)<\/em>/gi, "*$1*");
  md = md.replace(/<i[^>]*>(.*?)<\/i>/gi, "*$1*");

  // 링크
  md = md.replace(/<a[^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/gi, "[$2]($1)");

  // 이미지
  md = md.replace(/<img[^>]*src="([^"]*)"[^>]*alt="([^"]*)"[^>]*\/?>/gi, "![$2]($1)");
  md = md.replace(/<img[^>]*src="([^"]*)"[^>]*\/?>/gi, "![]($1)");

  // 코드
  md = md.replace(/<pre[^>]*><code[^>]*>(.*?)<\/code><\/pre>/gis, "```\n$1\n```\n\n");
  md = md.replace(/<code[^>]*>(.*?)<\/code>/gi, "`$1`");

  // 리스트
  md = md.replace(/<li[^>]*>(.*?)<\/li>/gi, "- $1\n");
  md = md.replace(/<\/?[ou]l[^>]*>/gi, "\n");

  // 단락 및 브레이크
  md = md.replace(/<br\s*\/?>/gi, "\n");
  md = md.replace(/<\/p>/gi, "\n\n");
  md = md.replace(/<p[^>]*>/gi, "");

  // 테이블 (기본 텍스트로 변환)
  md = md.replace(/<tr[^>]*>/gi, "|");
  md = md.replace(/<\/tr>/gi, "\n");
  md = md.replace(/<t[dh][^>]*>(.*?)<\/t[dh]>/gi, " $1 |");

  // 나머지 태그 제거
  md = md.replace(/<[^>]+>/g, "");

  // HTML 엔티티 디코딩
  md = md.replace(/&amp;/g, "&");
  md = md.replace(/&lt;/g, "<");
  md = md.replace(/&gt;/g, ">");
  md = md.replace(/&quot;/g, '"');
  md = md.replace(/&#39;/g, "'");
  md = md.replace(/&nbsp;/g, " ");

  // 연속 빈 줄 정리
  md = md.replace(/\n{3,}/g, "\n\n");

  return md.trim();
}

// ─── 텍스트 추출 (HTML 태그 전부 제거) ──────────────────────

function htmlToText(html) {
  let text = html;
  text = text.replace(/<br\s*\/?>/gi, "\n");
  text = text.replace(/<\/p>/gi, "\n\n");
  text = text.replace(/<\/?[ou]l[^>]*>/gi, "\n");
  text = text.replace(/<\/li>/gi, "\n");
  text = text.replace(/<tr[^>]*>/gi, "\n");
  text = text.replace(/<[^>]+>/g, "");
  text = text.replace(/&amp;/g, "&");
  text = text.replace(/&lt;/g, "<");
  text = text.replace(/&gt;/g, ">");
  text = text.replace(/&quot;/g, '"');
  text = text.replace(/&#39;/g, "'");
  text = text.replace(/&nbsp;/g, " ");
  text = text.replace(/\n{3,}/g, "\n\n");
  return text.trim();
}

// ─── 메인 ───────────────────────────────────────────────────

async function main() {
  const args = parseArgs(process.argv);

  if (!args.url) {
    process.stderr.write(
      "사용법: node web_fetch_js.mjs <url> [--wait 2000] [--timeout 30000] [--format markdown|text] [--selector body] [--max-chars 50000] [--no-headless]\n"
    );
    process.exit(1);
  }

  // URL 유효성 검사
  try {
    new URL(args.url);
  } catch {
    process.stderr.write(`오류: 잘못된 URL — ${args.url}\n`);
    process.exit(1);
  }

  let browser;
  try {
    browser = await chromium.launch({
      headless: args.headless,
      args: [
        "--no-sandbox",
        "--disable-setuid-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
      ],
    });

    const context = await browser.newContext({
      userAgent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
      viewport: { width: 1280, height: 720 },
      ignoreHTTPSErrors: true,
    });

    const page = await context.newPage();

    // 네트워크 타임아웃
    page.setDefaultTimeout(args.timeout);

    // 네비게이션 (JS 렌더링 자동 대기)
    await page.goto(args.url, {
      waitUntil: "domcontentloaded",
      timeout: args.timeout,
    });

    // 추가 JS 렌더링 대기
    if (args.wait > 0) {
      await page.waitForTimeout(args.wait);
    }

    // 대상 요소 추출
    const element = await page.$(args.selector);
    if (!element) {
      process.stderr.write(
        `오류: 선택자 "${args.selector}"를 찾을 수 없습니다\n`
      );
      process.exit(1);
    }

    const html = await element.innerHTML();

    // 변환
    const result =
      args.format === "markdown"
        ? htmlToMarkdown(html)
        : htmlToText(html);

    // 길이 제한
    const output =
      result.length > args.maxChars
        ? result.slice(0, args.maxChars) + "\n\n[...truncated]"
        : result;

    process.stdout.write(output + "\n");
  } catch (err) {
    process.stderr.write(`오류: ${err.message}\n`);
    process.exit(1);
  } finally {
    if (browser) {
      await browser.close();
    }
  }
}

main();
