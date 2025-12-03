# How to Save HTML Page via FlareSolverr on Mac

## Simple One-Line Command

```bash
curl -X POST http://localhost:8191/v1 -H "Content-Type: application/json" -d '{"cmd":"request.get","url":"https://dotacoach.gg/en/heroes/counters/magnus","maxTimeout":60000}' | python3 -c "import sys, json; print(json.load(sys.stdin)['solution']['response'])" > magnus_counters.html
```

## Prerequisites

1. **Install FlareSolverr** (one-time setup):
   ```bash
   docker run -d -p 8191:8191 --name flaresolverr ghcr.io/flaresolverr/flaresolverr:latest
   ```

2. **That's it!** Now you can use the command above.

## Usage

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
