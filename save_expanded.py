#!/usr/bin/env python3
"""
Save HTML page with expanded/clicked buttons using Playwright.

This script uses Playwright to load a page, click all buttons to expand content,
and then save the resulting HTML.

Usage:
    python3 save_expanded.py [url] [output_file]

Example:
    python3 save_expanded.py "https://dotacoach.gg/en/heroes/counters/magnus" magnus_expanded.html
"""

from playwright.sync_api import sync_playwright
import sys

def save_page_with_expanded_content(url, output_file):
    """
    Load a page, click all expandable buttons, and save the HTML.
    
    Args:
        url: The URL to load
        output_file: Where to save the HTML
    """
    with sync_playwright() as p:
        # Launch browser
        browser = p.chromium.launch()
        page = browser.new_page()
        
        print(f"Loading: {url}")
        page.goto(url)
        
        # Wait for page to fully load
        print("Waiting for page to load...")
        page.wait_for_load_state("networkidle")
        page.wait_for_timeout(2000)  # Additional 2 second wait
        
        # Try to click all buttons
        print("Clicking buttons to expand content...")
        buttons = page.query_selector_all("button")
        clicked_count = 0
        
        for i, button in enumerate(buttons):
            try:
                # Check if button is visible and enabled
                if button.is_visible() and button.is_enabled():
                    button.click()
                    clicked_count += 1
                    # Wait a bit for content to expand
                    page.wait_for_timeout(300)
            except Exception as e:
                # Skip buttons that can't be clicked
                pass
        
        print(f"Clicked {clicked_count} buttons")
        
        # Give page time to settle after all clicks
        page.wait_for_timeout(1000)
        
        # Save the HTML
        html = page.content()
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(html)
        
        browser.close()
        print(f"✓ Saved to: {output_file}")
        print(f"  HTML size: {len(html):,} bytes")


if __name__ == "__main__":
    # Parse command line arguments
    url = sys.argv[1] if len(sys.argv) > 1 else "https://dotacoach.gg/en/heroes/counters/magnus"
    output = sys.argv[2] if len(sys.argv) > 2 else "output_expanded.html"
    
    try:
        save_page_with_expanded_content(url, output)
    except Exception as e:
        print(f"✗ Error: {e}", file=sys.stderr)
        sys.exit(1)
