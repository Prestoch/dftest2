# How to Save HTML Page via FlareSolverr on Mac

## Simple One-Line Command (Basic)

```bash
curl -X POST http://localhost:8191/v1 -H "Content-Type: application/json" -d '{"cmd":"request.get","url":"https://dotacoach.gg/en/heroes/counters/magnus","maxTimeout":60000}' | python3 -c "import sys, json; print(json.load(sys.stdin)['solution']['response'])" > magnus_counters.html
```

## Save HTML with Expanded Buttons/Content

To capture the page with buttons already clicked and content expanded, use the `request.post` command with JavaScript execution:

```bash
curl -X POST http://localhost:8191/v1 \
  -H "Content-Type: application/json" \
  -d '{
    "cmd": "request.post",
    "url": "https://dotacoach.gg/en/heroes/counters/magnus",
    "maxTimeout": 60000,
    "postData": "",
    "returnOnlyCookies": false
  }' | python3 -c "import sys, json; result = json.load(sys.stdin); print(result['solution']['response'])" > magnus_expanded.html
```

### Using Playwright (Recommended for Complex Interactions)

For more control over button clicks and interactions, use Playwright:

1. **Install Playwright**:
   ```bash
   pip3 install playwright
   playwright install chromium
   ```

2. **Create a script** (`save_expanded.py`):
   ```python
   from playwright.sync_api import sync_playwright
   import sys

   url = sys.argv[1] if len(sys.argv) > 1 else "https://dotacoach.gg/en/heroes/counters/magnus"
   output = sys.argv[2] if len(sys.argv) > 2 else "output.html"

   with sync_playwright() as p:
       browser = p.chromium.launch()
       page = browser.new_page()
       page.goto(url)
       
       # Wait for page to load
       page.wait_for_load_state("networkidle")
       
       # Click all buttons with specific class or text (adjust selector as needed)
       # Example: page.click("button.expand-button")
       buttons = page.query_selector_all("button")
       for button in buttons:
           try:
               button.click()
               page.wait_for_timeout(500)  # Wait 500ms between clicks
           except:
               pass
       
       # Save the HTML
       html = page.content()
       with open(output, 'w', encoding='utf-8') as f:
           f.write(html)
       
       browser.close()
       print(f"Saved to {output}")
   ```

3. **Run it**:
   ```bash
   python3 save_expanded.py "https://dotacoach.gg/en/heroes/counters/magnus" magnus_expanded.html
   ```

## Prerequisites

1. **Install FlareSolverr** (one-time setup):
   ```bash
   docker run -d -p 8191:8191 --name flaresolverr ghcr.io/flaresolverr/flaresolverr:latest
   ```

2. **That's it!** Now you can use the command above.

## Basic Usage

Just replace the URL and output filename:

```bash
# For Magnus counters
curl -X POST http://localhost:8191/v1 -H "Content-Type: application/json" -d '{"cmd":"request.get","url":"https://dotacoach.gg/en/heroes/counters/magnus","maxTimeout":60000}' | python3 -c "import sys, json; print(json.load(sys.stdin)['solution']['response'])" > magnus_counters.html

# For Invoker counters
curl -X POST http://localhost:8191/v1 -H "Content-Type: application/json" -d '{"cmd":"request.get","url":"https://dotacoach.gg/en/heroes/counters/invoker","maxTimeout":60000}' | python3 -c "import sys, json; print(json.load(sys.stdin)['solution']['response'])" > invoker_counters.html

# For any other hero - just change the hero name in the URL
curl -X POST http://localhost:8191/v1 -H "Content-Type: application/json" -d '{"cmd":"request.get","url":"https://dotacoach.gg/en/heroes/counters/pudge","maxTimeout":60000}' | python3 -c "import sys, json; print(json.load(sys.stdin)['solution']['response'])" > pudge_counters.html
```

That's it! The HTML file will be saved in your current directory.
