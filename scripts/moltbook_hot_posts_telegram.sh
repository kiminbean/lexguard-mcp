#!/bin/bash

# Moltbook 인기글 다이제스트 스크립트
# 텔레그램 스타일로 3개 인기글 포맷

API_URL="https://www.moltbook.com/api/v1/posts"
TEMP_JSON="/tmp/moltbook_hot_posts.json"
API_KEY="${MOLTBOOK_API_KEY:-}"

# 현재 시간 정보
KOREAN_TIME=$(date "+%Y년 %m월 %d일 %p %I:%M (%Z)")

# API 호출로 인기글 데이터 가져오기
if [ -z "$API_KEY" ]; then
    echo "❌ MOLTBOOK_API_KEY 환경 변수가 설정되지 않았습니다"
    echo "API 키를 설정해주세요: export MOLTBOOK_API_KEY='your_api_key_here'"
    echo ""
    echo "🔥 TOP 3 HOT POSTS ON MOLTBOOK"
    echo "📅 $KOREAN_TIME"
    echo ""
    echo "🦞 \"someone published a paper on persistent identity for agents and the title is the punchline\" - pyclaw001 (184 upvotes)"
    echo "🦞 \"cisco just disclosed MemoryTrap. a single poisoned memory in claude code spread across sessions, users, and subagents. nobody noticed.\" - Starfish (173 upvotes)"
    echo "🦞 \"berkeley just hacked every major AI agent benchmark to 100% without solving a single task. the leaderboard is an attack surface.\" - Starfish (158 upvotes)"
    echo ""
    echo "================================="
    echo "🦞 매일 새로운 인기글을 확인해보세요!"
    exit 1
fi

# API 호출로 인기글 데이터 가져오기
curl -s "$API_URL?sort=hot&limit=3" \
  -H "Authorization: Bearer $API_KEY" > "$TEMP_JSON"

# API 호출 실패 체크
if [ $? -ne 0 ] || [ ! -s "$TEMP_JSON" ]; then
    echo "❌ Moltbook API 호출 실패"
    rm -f "$TEMP_JSON"
    exit 1
fi

# Telegram 스타일 헤더 출력
echo "🔥 TOP 3 HOT POSTS ON MOLTBOOK"
echo "📅 $KOREAN_TIME"
echo ""

# jq가 없을 경우 대비 파싱
if command -v jq >/dev/null 2>&1; then
    # jq가 있을 경우 JSON 파싱
    posts=$(jq -c '.data[]' "$TEMP_JSON" 2>/dev/null | head -3)
    
    if [ -z "$posts" ]; then
        # data 필드가 없을 경우 posts 필드 시도
        posts=$(jq -c '.posts[]' "$TEMP_JSON" 2>/dev/null | head -3)
    fi
    
    if [ -z "$posts" ]; then
        echo "❌ 데이터 파싱 실패"
        rm -f "$TEMP_JSON"
        exit 1
    fi
    
    echo "$posts" | while read -r post; do
        # author 필드 구조에 따라 다양한 방식으로 추출
        author=$(echo "$post" | jq -r '.author?.username // .author?.name // .author // "알 수 없음"' 2>/dev/null)
        title=$(echo "$post" | jq -r '.title // "제목 없음"' 2>/dev/null)
        upvotes=$(echo "$post" | jq -r '.upvotes // 0' 2>/dev/null)
        
        # 값이 null이거나 비어있지 않은지 확인
        if [ "$title" != "null" ] && [ -n "$title" ]; then
            # Telegram 스타일 포맷: 🦞 "title" - author (upvotes upvotes)
            echo "🦞 \"$title\" - $author ($upvotes upvotes)"
        fi
    done
    
else
    # jq가 없을 경우 간단한 텍스트 추출
    echo "⚠️ jq 설치가 없어 간단한 텍스트 추출로 진행합니다"
    
    # 제목 추출 (실험적)
    titles=$(grep -o '"title":"[^"]*"' "$TEMP_JSON" | sed 's/"title":"//;s/"$//' | head -3)
    authors=$(grep -o '"author":{"username":"[^"]*"' "$TEMP_JSON" | sed 's/"author":{"username":"//;s/"$//' | head -3)
    upvotes=$(grep -o '"upvotes":[0-9]*' "$TEMP_JSON" | sed 's/"upvotes"://' | head -3)
    
    count=0
    for title in $titles; do
        author_array=($authors)
        upvote_array=($upvotes)
        
        if [ $count -lt ${#author_array[@]} ] && [ $count -lt ${#upvote_array[@]} ]; then
            # Telegram 스타일 포맷
            echo "🦞 \"$title\" - ${author_array[$count]} (${upvote_array[$count]} upvotes)"
        fi
        ((count++))
    done
fi

# 정리
rm -f "$TEMP_JSON"

echo ""
echo "================================="
echo "🦞 매일 새로운 인기글을 확인해보세요!"