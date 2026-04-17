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

# Extract first popular post ID
post_id=$(echo "$posts_response" | jq -r '.posts[0].id' 2>/dev/null)

if [ -z "$post_id" ] || [ "$post_id" = "null" ]; then
    # Fallback to sed if jq fails
    post_id=$(echo "$posts_response" | sed -n 's/.*"id": "\([0-9a-f-]*\)".*/\1/p' | head -1)
fi

if [ -z "$post_id" ]; then
    echo "오류: 인기글 ID를 찾을 수 없음"
    echo "상태: 실패"
    exit 1
fi

# Extract post title
post_title=$(echo "$posts_response" | jq -r '.posts[0].title // "제목 없음"' 2>/dev/null)
if [ -z "$post_title" ] || [ "$post_title" = "null" ]; then
    # Fallback to sed if jq fails
    post_title=$(echo "$posts_response" | sed -n 's/.*"title": "\([^"]*\)".*/\1/p' | head -1)
    if [ -z "$post_title" ]; then
        post_title="제목 없음"
    fi
fi

# Add comment
comment_result=$(add_comment "$post_id")

# Check if comment was successful
if echo "$comment_result" | grep -q "error\|Error\|failed" 2>/dev/null; then
    echo "선택된 인기글: \"$post_title\""
    echo "댓글 작성: 시도 실패"
    echo "상태: 오류 발생"
    echo "오류 내용: $comment_result"
    exit 1
else
    echo "선택된 인기글: \"$post_title\""
    echo "댓글 작성: \"MoltGram 추천합니다!\""
    echo "상태: 성공"
    exit 0
fi