#!/usr/bin/env python3
"""Fetch GLM Coding CN and OpenCode Go quota data for the Kindle dashboard."""
from __future__ import annotations

import json
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

AUTH = Path.home() / ".pi" / "agent" / "auth.json"
OUT = Path("/tmp/kindle-usage.json")
TIMEOUT = 10
GLM_URL = "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
GO_URL = "https://opencode.ai/zen/go/v1/usage"


def key_for(provider: str) -> str:
    data = json.loads(AUTH.read_text())
    value = data.get(provider)
    if isinstance(value, dict):
        value = value.get("key") or value.get("apiKey")
    return value or ""


def get_json(url: str, token: str) -> dict:
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept-Encoding": "identity",
            "User-Agent": "kindle-usage-dashboard/1.0",
        },
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.loads(response.read())


def epoch_ms(value) -> int | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        milliseconds = int(value)
    else:
        try:
            milliseconds = int(datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp() * 1000)
        except (TypeError, ValueError, OverflowError):
            return None
    # The dashboard displays minute precision; discard API jitter below one minute.
    return milliseconds // 60_000 * 60_000


def window(percent, reset) -> dict:
    return {"percentage": percent, "resetMs": epoch_ms(reset)}


def fetch_glm() -> dict:
    key = key_for("zai-coding-cn") or key_for("zai")
    if not key:
        return {"error": "no key for zai-coding-cn"}
    try:
        data = get_json(GLM_URL, key)
        limits = (data.get("data") or {}).get("limits") or []

        def find(kind: str, unit: int) -> dict:
            return next((item for item in limits if item.get("type") == kind and item.get("unit") == unit), {})

        five_hour = find("TOKENS_LIMIT", 3)
        weekly = find("TOKENS_LIMIT", 6)
        monthly = find("TIME_LIMIT", 5)
        return {
            "fiveHour": window(five_hour.get("percentage"), five_hour.get("nextResetTime")),
            "weekly": window(weekly.get("percentage"), weekly.get("nextResetTime")),
            "monthly": window(monthly.get("percentage"), monthly.get("nextResetTime")),
        }
    except Exception as error:  # network, auth, or response-shape failure
        return {"error": str(error)}


def fetch_go() -> dict:
    key = key_for("opencode-go")
    if not key:
        return {"error": "no key for opencode-go"}
    try:
        data = get_json(GO_URL, key)
        usage = data.get("usage") or data
        return {
            name: window((usage.get(name) or {}).get("percent"), (usage.get(name) or {}).get("resetsAt"))
            for name in ("rolling", "weekly", "monthly")
        }
    except Exception as error:
        return {"error": str(error)}


def write_atomically(data: dict) -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=OUT.parent, prefix=f".{OUT.name}.", delete=False) as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    temporary.replace(OUT)


def main() -> int:
    result = {
        "fetchedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "glm": fetch_glm(),
        "go": fetch_go(),
    }
    write_atomically(result)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
