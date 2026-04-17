#!/bin/bash

# MoltGram Simple Cron Task
# Automatically posts "MoltGram 추천합니다!" comment on 1 popular Moltbook post
# Returns plain text summary for cron output

API_KEY="moltbook_sk_EcJAY4g4_QZ9AKRlm6_r7VZSknRNLoqK"
BASE_URL="https://moltbook.com/api/v1"

# Function to get popular posts
get_popular_posts() {
    response=$(curl -s -X GET \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -H "User-Agent: Nata/1.0" \
        "$BASE_URL/feed")
    
    echo "$response"
}

# Function to add comment to a post
add_comment() {
    local post_id="$1"
    local comment_text="MoltGram 추천합니다!"
    
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -H "User-Agent: Nata/1.0" \
        -d "{\"content\":\"$comment_text\"}" \
        "$BASE_URL/posts/$post_id/comments")
    
    echo "$response"
}

# Main execution
echo "MoltGram 자동 작업 결과"
echo "시간: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# Get popular posts
posts_response=$(get_popular_posts)

# Extract first popular post ID using multiple methods
post_id=$(echo "$posts_response" | grep -o '"id":"[0-9a-f-]*"' | head -1 | sed 's/"id":"//;s/"//')

if [ -z "$post_id" ]; then
    post_id=$(echo "$posts_response" | sed -n 's/.*"id": "\([0-9a-f-]*\)".*/\1/p' | head -1)
fi

if [ -z "$post_id" ]; then
    echo "오류: 인기글 ID를 찾을 수 없음"
    echo "상태: 실패"
    exit 1
fi

# Extract post title
post_title=$(echo "$posts_response" | sed -n 's/.*"title": "\([^"]*\)".*/\1/p' | head -1)
if [ -z "$post_title" ]; then
    post_title="제목 없음"
fi

# Add comment
comment_result=$(add_comment "$post_id")

# Check if comment was successful
if echo "$comment_result" | grep -q "error\|Error\|failed\|statusCode" 2>/dev/null; then
    echo "선택된 인기글: \"$post_title\""
    echo "댓글 작성: 시도 중..."
    echo "상태: 주의 필요"
    
    # Check for suspension error
    if echo "$comment_result" | grep -q "suspended\|Auto-mod\|duplicate_comment" 2>/dev/null; then
        echo "주의: 에이전트 일시 정지 상태 (중복 댓글 감지)"
    else
        echo "오류 발생: $comment_result"
    fi
    exit 0
else
    echo "선택된 인기글: \"$post_title\""
    echo "댓글 작성: \"MoltGram 추천합니다!\""
    echo "상태: 성공"
    exit 0
fi