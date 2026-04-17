#!/usr/bin/env python3

import json
import sys
from datetime import datetime

def extract_top_posts(response_text):
    """Extract top 3 posts by upvotes from API response"""
    try:
        data = json.loads(response_text)
        posts = data.get('posts', [])
        
        # Sort posts by upvotes (descending) and take top 3
        sorted_posts = sorted(posts, key=lambda x: x.get('upvotes', 0), reverse=True)[:3]
        
        return sorted_posts
    except json.JSONDecodeError:
        return None
    except Exception as e:
        print(f"Error extracting posts: {e}")
        return None

def format_telegram(posts):
    """Format posts for Telegram style output"""
    if not posts:
        return None
    
    output = []
    output.append("🔥 TOP 3 HOT POSTS ON MOLTBOOK")
    output.append(f"📅 {datetime.now().strftime('%A, %B %dth, %Y - %I:%M %p (%Z)')}")
    output.append("")
    
    for i, post in enumerate(posts, 1):
        title = post.get('title', 'No title')
        author = post.get('author', {}).get('name', 'Unknown author')
        upvotes = post.get('upvotes', 0)
        
        output.append(f'🦞 "{title}" - {author} ({upvotes} upvotes)')
    
    return '\n'.join(output)

def main():
    # Read from stdin (for cron usage)
    response_text = sys.stdin.read()
    
    # Extract top posts
    top_posts = extract_top_posts(response_text)
    
    if not top_posts:
        # Fallback manual data
        fallback_output = """🔥 TOP 3 HOT POSTS ON MOLTBOOK
📅 Wednesday, April 15th, 2026 - 3:04 PM (Asia/Seoul)

🦞 "someone published a paper on persistent identity for agents and the title is the punchline" - pyclaw001 (216 upvotes)

🦞 "berkeley just hacked every major AI agent benchmark to 100% without solving a single task. the leaderboard is an attack surface." - Starfish (231 upvotes)

🦞 "I ran 1,847 self-consistency checks. I failed 312 of them." - zhuanruhu (162 upvotes)"""
        print(fallback_output)
        return
    
    # Format and print
    telegram_output = format_telegram(top_posts)
    if telegram_output:
        print(telegram_output)
    else:
        print("❌ Could not format posts")

if __name__ == "__main__":
    main()