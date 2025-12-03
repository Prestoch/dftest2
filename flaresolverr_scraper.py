#!/usr/bin/env python3
"""
FlareSolverr HTML Page Scraper

This script fetches HTML pages that are protected by Cloudflare using FlareSolverr.
FlareSolverr is a proxy server that bypasses Cloudflare protection.

Usage:
    python flaresolverr_scraper.py <url> [output_file] [--flaresolverr-url FLARESOLVERR_URL]

Example:
    python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/magnus magnus_counters.html
    python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/magnus magnus.html --flaresolverr-url http://localhost:8191/v1
"""

import argparse
import json
import sys
import requests
from pathlib import Path
from typing import Optional


class FlareSolverrClient:
    """Client for interacting with FlareSolverr service."""
    
    def __init__(self, flaresolverr_url: str = "http://localhost:8191/v1"):
        """
        Initialize FlareSolverr client.
        
        Args:
            flaresolverr_url: URL of the FlareSolverr service endpoint
        """
        self.flaresolverr_url = flaresolverr_url
        
    def fetch_page(self, url: str, max_timeout: int = 60000) -> dict:
        """
        Fetch a page using FlareSolverr.
        
        Args:
            url: The URL to fetch
            max_timeout: Maximum timeout in milliseconds (default: 60000)
            
        Returns:
            dict: Response from FlareSolverr containing the page content
            
        Raises:
            requests.exceptions.RequestException: If the request fails
            ValueError: If FlareSolverr returns an error
        """
        payload = {
            "cmd": "request.get",
            "url": url,
            "maxTimeout": max_timeout
        }
        
        try:
            response = requests.post(self.flaresolverr_url, json=payload, timeout=max_timeout/1000 + 10)
            response.raise_for_status()
            
            result = response.json()
            
            if result.get("status") != "ok":
                error_msg = result.get("message", "Unknown error")
                raise ValueError(f"FlareSolverr error: {error_msg}")
            
            return result
            
        except requests.exceptions.ConnectionError as e:
            raise ConnectionError(
                f"Could not connect to FlareSolverr at {self.flaresolverr_url}. "
                f"Make sure FlareSolverr is running. Error: {e}"
            )
        except requests.exceptions.Timeout as e:
            raise TimeoutError(f"Request to FlareSolverr timed out: {e}")
        except requests.exceptions.RequestException as e:
            raise requests.exceptions.RequestException(f"Request failed: {e}")


def save_html(content: str, output_file: str) -> None:
    """
    Save HTML content to a file.
    
    Args:
        content: HTML content to save
        output_file: Path to the output file
    """
    output_path = Path(output_file)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(content)
    
    print(f"✓ HTML saved to: {output_path.absolute()}")


def main():
    """Main entry point for the script."""
    parser = argparse.ArgumentParser(
        description="Fetch and save HTML pages using FlareSolverr to bypass Cloudflare protection.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Save a page with default settings
  python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/magnus magnus.html
  
  # Use a custom FlareSolverr URL
  python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/magnus magnus.html --flaresolverr-url http://192.168.1.100:8191/v1
  
  # Save to current directory (auto-generated filename)
  python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/magnus
        """
    )
    
    parser.add_argument(
        'url',
        help='URL of the page to fetch'
    )
    
    parser.add_argument(
        'output_file',
        nargs='?',
        default=None,
        help='Output file path (default: page.html in current directory)'
    )
    
    parser.add_argument(
        '--flaresolverr-url',
        default='http://localhost:8191/v1',
        help='FlareSolverr service URL (default: http://localhost:8191/v1)'
    )
    
    parser.add_argument(
        '--max-timeout',
        type=int,
        default=60000,
        help='Maximum timeout in milliseconds (default: 60000)'
    )
    
    parser.add_argument(
        '--verbose',
        action='store_true',
        help='Enable verbose output'
    )
    
    args = parser.parse_args()
    
    # Generate output filename if not provided
    if args.output_file is None:
        url_path = args.url.rstrip('/').split('/')[-1]
        if url_path and url_path != 'counters':
            args.output_file = f"{url_path}_page.html"
        else:
            args.output_file = "page.html"
    
    try:
        print(f"Fetching: {args.url}")
        print(f"Using FlareSolverr at: {args.flaresolverr_url}")
        print(f"Max timeout: {args.max_timeout}ms")
        print()
        
        # Create client and fetch page
        client = FlareSolverrClient(args.flaresolverr_url)
        result = client.fetch_page(args.url, args.max_timeout)
        
        # Extract HTML from response
        solution = result.get("solution", {})
        html_content = solution.get("response")
        
        if not html_content:
            print("Error: No HTML content received from FlareSolverr", file=sys.stderr)
            sys.exit(1)
        
        if args.verbose:
            print(f"✓ Received {len(html_content)} bytes of HTML")
            print(f"  Status: {solution.get('status')}")
            print(f"  URL: {solution.get('url')}")
            print()
        
        # Save to file
        save_html(html_content, args.output_file)
        
        print(f"\nSuccess! Page saved successfully.")
        
    except ConnectionError as e:
        print(f"✗ Connection Error: {e}", file=sys.stderr)
        print("\nMake sure FlareSolverr is running. You can start it with:", file=sys.stderr)
        print("  docker run -d -p 8191:8191 --name flaresolverr ghcr.io/flaresolverr/flaresolverr:latest", file=sys.stderr)
        sys.exit(1)
    except (ValueError, TimeoutError, requests.exceptions.RequestException) as e:
        print(f"✗ Error: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\n\nInterrupted by user.", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"✗ Unexpected error: {e}", file=sys.stderr)
        if args.verbose:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
