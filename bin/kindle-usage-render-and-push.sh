#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-/opt/homebrew/bin/python3}"
FETCHER="${FETCHER:-$SCRIPT_DIR/kindle-usage-fetch.py}"
RENDERER="${RENDERER:-$SCRIPT_DIR/kindle-usage-png.py}"
PUSHER="${PUSHER:-$SCRIPT_DIR/kindle-usage-push-kindle.sh}"
PNG="${PNG:-/tmp/kindle-usage-dashboard.png}"
USAGE="${USAGE:-/tmp/kindle-usage.json}"
STATE="${STATE:-/tmp/kindle-usage-dashboard.last.sha256}"
LOCK="${LOCK:-/tmp/kindle-usage-dashboard.lock}"
ROTATION="${KINDLE_USAGE_ROTATION:-270}"

if ! mkdir "$LOCK" 2>/dev/null; then
  echo "usage dashboard already running; skipping"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

"$PYTHON" "$FETCHER" >/dev/null 2>&1 || echo "usage fetch failed; using cached data" >&2

new_state="$($PYTHON - "$USAGE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

# Fetch timestamps and transient provider errors are not display state.
def stable(value):
    if isinstance(value, dict):
        if "error" in value:
            return None
        return {k: stable(v) for k, v in value.items() if k != "fetchedAt"}
    if isinstance(value, list):
        return [stable(v) for v in value]
    return value

encoded = json.dumps(stable(data), ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
print(hashlib.sha256(encoded).hexdigest())
PY
)"

if [[ -f "$STATE" ]] && [[ "$(<"$STATE")" == "$new_state" ]]; then
  echo "usage unchanged; skipping Kindle refresh"
  exit 0
fi

"$PYTHON" "$RENDERER" --usage "$USAGE" --output "$PNG" --rotation "$ROTATION"

set +e
push_output="$(PNG="$PNG" REMOTE_PNG="${REMOTE_PNG:-/mnt/us/extensions/kindle-usage-dashboard.png}" "$PUSHER" 2>&1)"
push_rc=$?
set -e
printf '%s\n' "$push_output"
if (( push_rc != 0 )); then
  exit "$push_rc"
fi

if printf '%s\n' "$push_output" | grep -q '^Pushed .* to Kindle display at '; then
  printf '%s\n' "$new_state" > "$STATE"
else
  echo "Kindle push was skipped; retaining the previous state hash" >&2
fi
