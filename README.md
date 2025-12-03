# FlareSolverr HTML Page Scraper

A Python script to fetch and save HTML pages that are protected by Cloudflare using FlareSolverr.

## What is FlareSolverr?

[FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) is a proxy server that bypasses Cloudflare and DDoS-GUARD protection. It's useful for web scraping sites that use these protections.

## Prerequisites

### 1. Install Python Dependencies

```bash
pip install -r requirements.txt
```

### 2. Install and Run FlareSolverr

#### Using Docker (Recommended)

```bash
docker run -d \
  --name flaresolverr \
  -p 8191:8191 \
  -e LOG_LEVEL=info \
  --restart unless-stopped \
  ghcr.io/flaresolverr/flaresolverr:latest
```

#### Using Docker Compose

Create a `docker-compose.yml` file:

```yaml
version: '3.8'

services:
  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    ports:
      - "8191:8191"
    environment:
      - LOG_LEVEL=info
    restart: unless-stopped
```

Then run:

```bash
docker-compose up -d
```

#### Verify FlareSolverr is Running

```bash
curl http://localhost:8191/v1
```

You should see a JSON response indicating the service is running.

## Usage

### Basic Usage

Save a page with an auto-generated filename:

```bash
python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/magnus
```

### Specify Output File

```bash
python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/magnus magnus_counters.html
```

### Custom FlareSolverr URL

If FlareSolverr is running on a different host or port:

```bash
python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/magnus magnus.html --flaresolverr-url http://192.168.1.100:8191/v1
```

### Verbose Output

Enable detailed output:

```bash
python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/magnus magnus.html --verbose
```

### Custom Timeout

Set a custom timeout (in milliseconds):

```bash
python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/magnus magnus.html --max-timeout 120000
```

## Command-Line Options

```
usage: flaresolverr_scraper.py [-h] [--flaresolverr-url FLARESOLVERR_URL]
                               [--max-timeout MAX_TIMEOUT] [--verbose]
                               url [output_file]

positional arguments:
  url                   URL of the page to fetch
  output_file          Output file path (default: page.html)

optional arguments:
  -h, --help           show this help message and exit
  --flaresolverr-url FLARESOLVERR_URL
                       FlareSolverr service URL (default: http://localhost:8191/v1)
  --max-timeout MAX_TIMEOUT
                       Maximum timeout in milliseconds (default: 60000)
  --verbose            Enable verbose output
```

## Example: Scraping DotaCoach Pages

### Save Magnus Counter Page

```bash
python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/magnus magnus_counters.html
```

### Save Multiple Hero Pages

```bash
# Magnus
python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/magnus magnus_counters.html

# Invoker
python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/invoker invoker_counters.html

# Pudge
python flaresolverr_scraper.py https://dotacoach.gg/en/heroes/counters/pudge pudge_counters.html
```

### Batch Script

Create a bash script to scrape multiple pages:

```bash
#!/bin/bash

heroes=("magnus" "invoker" "pudge" "anti-mage" "phantom-assassin")

for hero in "${heroes[@]}"; do
    echo "Fetching $hero..."
    python flaresolverr_scraper.py \
        "https://dotacoach.gg/en/heroes/counters/$hero" \
        "${hero}_counters.html"
    sleep 2  # Be nice to the server
done
```

## Troubleshooting

### "Could not connect to FlareSolverr"

**Problem**: The script can't connect to FlareSolverr.

**Solution**:
1. Make sure FlareSolverr is running:
   ```bash
   docker ps | grep flaresolverr
   ```
2. Verify the service is accessible:
   ```bash
   curl http://localhost:8191/v1
   ```
3. Check if you need to use a different URL (e.g., if running on another machine)

### "Request timed out"

**Problem**: The page takes too long to load.

**Solution**:
- Increase the timeout using `--max-timeout`:
  ```bash
  python flaresolverr_scraper.py <url> --max-timeout 120000
  ```

### "FlareSolverr error"

**Problem**: FlareSolverr encountered an error while fetching the page.

**Solution**:
1. Check FlareSolverr logs:
   ```bash
   docker logs flaresolverr
   ```
2. Try the request again (sometimes Cloudflare challenges are unpredictable)
3. Verify the URL is correct and accessible

## How It Works

1. The script sends a request to FlareSolverr with the target URL
2. FlareSolverr uses a headless browser to:
   - Navigate to the URL
   - Solve any Cloudflare challenges
   - Wait for the page to fully load
3. FlareSolverr returns the complete HTML content
4. The script saves the HTML to the specified file

## Integration with Existing Project

This script is designed to work alongside the existing DotaBuff Counter Picker project. You can use it to:

1. Scrape hero counter data from DotaCoach
2. Parse the HTML to extract counter information
3. Convert it to the format used by `cs.json`
4. Update the counter picker with fresh data

## Notes

- FlareSolverr can be resource-intensive as it runs a headless browser
- Be respectful of the target website's resources (add delays between requests)
- Some websites may detect and block automated access even with FlareSolverr
- Always check the website's `robots.txt` and terms of service before scraping

## License

This script is provided as-is for educational purposes. Respect the terms of service of any website you scrape.
