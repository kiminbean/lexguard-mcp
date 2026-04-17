#!/bin/bash

# MoltGram 자동 댓글 작업 (단순화)
# 인기글 1개에 'MoltGram 추천합니다!' 댓글 작성

API_KEY="moltbook_sk_EcJAY4g4_QZ9AKRlm6_r7VZSknRNLoqK"
USER_AGENT="Nata/1.0"

# 인기글 가져오기 (API URL 수정)
response=$(curl -s -X GET \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    "https://moltbook.com/api/v1/feed")

# 첫 번째 인기글 ID 추출 (개선된 방법)
post_id=$(echo "$response" | grep -o '"id":"[0-9a-f-]*"' | head -1 | sed 's/"id":"//;s/"//')

if [ -z "$post_id" ]; then
    # 대체 방법 시도
    post_id=$(echo "$response" | sed -n 's/.*"id": "\([0-9a-f-]*\)".*/\1/p' | head -1)
fi

if [ -z "$post_id" ]; then
    echo "인기글 ID를 찾을 수 없음"
    exit 1
fi

echo "선택된 글 ID: $post_id"

# 댓글 작성
comment_result=$(curl -s -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -d '{"content":"MoltGram 추천합니다!"}' \
    "https://moltbook.com/api/v1/posts/$post_id/comments")

# 결과 확인
if echo "$comment_result" | grep -q "error\|Error\|failed"; then
    echo "댓글 작성 실패"
    echo "Response: $comment_result"
    exit 1
else
    echo "댓글 작성 완료"
    exit 0
fi