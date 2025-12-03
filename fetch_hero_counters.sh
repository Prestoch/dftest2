#!/bin/bash
# Example script to fetch DotaCoach hero counter pages using FlareSolverr
# Usage: ./fetch_hero_counters.sh

# List of heroes to fetch
heroes=(
    "magnus"
    "invoker"
    "pudge"
    "anti-mage"
    "phantom-assassin"
)

echo "================================================"
echo "DotaCoach Hero Counter Page Fetcher"
echo "================================================"
echo ""
echo "This script will fetch counter pages for multiple heroes"
echo "Make sure FlareSolverr is running before continuing!"
echo ""
echo "Press Ctrl+C to cancel, or Enter to continue..."
read

# Create output directory
mkdir -p hero_counters

# Fetch each hero's counter page
for hero in "${heroes[@]}"; do
    echo ""
    echo "Fetching counter data for: $hero"
    echo "----------------------------------------"
    
    python3 flaresolverr_scraper.py \
        "https://dotacoach.gg/en/heroes/counters/$hero" \
        "hero_counters/${hero}_counters.html" \
        --verbose
    
    if [ $? -eq 0 ]; then
        echo "✓ Success: $hero"
    else
        echo "✗ Failed: $hero"
    fi
    
    # Be nice to the server - add a delay between requests
    if [ "$hero" != "${heroes[-1]}" ]; then
        echo ""
        echo "Waiting 3 seconds before next request..."
        sleep 3
    fi
done

echo ""
echo "================================================"
echo "Done! Check the hero_counters/ directory for the saved pages."
echo "================================================"
