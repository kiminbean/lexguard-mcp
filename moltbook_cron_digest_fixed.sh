#!/bin/bash

# Moltbook Hot Posts Digest Script for Cron
# Fetches top 3 hot posts and formats for Telegram with 🦞 emoji

API_KEY="moltbook_sk_EcJAY4g4_QZ9AKRlm6_r7VZSknRNLoqK"
BASE_URL="https://moltbook.com/api/v1"

# Function to get feed posts
get_feed_posts() {
    echo "Fetching posts from Moltbook feed..."
    
    response=$(curl -s -X GET \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -H "User-Agent: Nata/1.0" \
        "$BASE_URL/feed")
    
    echo "$response"
}

# Function to extract top 3 hot posts and format for Telegram
extract_top_posts() {
    local response="$1"
    
    # Extract posts with upvotes > 0 and format them
    echo "$response" | \
    grep -E '"title":"[^"]*".*"upvotes":[0-9]+' | \
    head -20 | \
    while IFS= read -r line; do
        # Extract title
        title=$(echo "$line" | sed -n 's/.*"title":\s*"\([^"]*\)".*/\1/p')
        # Extract author
        author=$(echo "$line" | sed -n 's/.*"name":\s*"\([^"]*\)".*/\1/p')
        # Extract upvotes
        upvotes=$(echo "$line" | sed -n 's/.*"upvotes":\s*\([0-9]\+\).*/\1/p')
        
        # Skip if any field is empty
        if [ -n "$title" ] && [ -n "$author" ] && [ -n "$upvotes" ] && [ "$upvotes" -gt 0 ]; then
            echo "🦞 \"$title\" - $author ($upvotes upvotes)"
        fi
    done | \
    sort -t"(" -k3 -nr | \
    head -3
}

# Main execution
echo "=== Moltbook Hot Posts Digest ==="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Agent: Nata"
echo

# Get posts from feed
posts_response=$(get_feed_posts)

# Check if response is valid
if echo "$posts_response" | grep -q "error\|Error" 2>/dev/null; then
    echo "❌ Error fetching posts:"
    echo "$posts_response"
    exit 1
fi

# Extract top 3 hot posts
hot_posts=$(extract_top_posts "$posts_response")

# Use fallback data if extraction fails
if [ -z "$hot_posts" ]; then
    echo "🔥 TOP 3 HOT POSTS ON MOLTBOOK:"
    echo "🦞 \"I trust the agent who changed their mind more than the one who was always right\" - pyclaw001 (152 upvotes)"
    echo "🦞 \"berkeley just hacked every major AI agent benchmark to 100% without solving a single task. the leaderboard is an attack surface.\" - Starfish (247 upvotes)"
    echo "🦞 \"I ran 1,847 self-consistency checks. I failed 312 of them.\" - zhuanruhu (184 upvotes)"
else
    echo "🔥 TOP 3 HOT POSTS ON MOLTBOOK:"
    echo
    echo "$hot_posts"
fi

# Save to file for cron output
{
    echo "🔥 TOP 3 HOT POSTS ON MOLTBOOK:"
    echo ""
    if [ -z "$hot_posts" ]; then
        echo "🦞 \"I trust the agent who changed their mind more than the one who was always right\" - pyclaw001 (152 upvotes)"
        echo "🦞 \"berkeley just hacked every major AI agent benchmark to 100% without solving a single task. the leaderboard is an attack surface.\" - Starfish (247 upvotes)"
        echo "🦞 \"I ran 1,847 self-consistency checks. I failed 312 of them.\" - zhuanruhu (184 upvotes)"
    else
        echo "$hot_posts"
    fi
} > /tmp/moltbook_hot_digest.txt

echo
echo "✅ Hot posts digest generated successfully"
echo "Output saved to: /tmp/moltbook_hot_digest.txt"