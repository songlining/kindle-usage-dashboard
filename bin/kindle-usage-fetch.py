#!/usr/bin/env python3
"""Fetch GLM Coding CN and OpenCode Go quota data for the Kindle dashboard."""
from __future__ import annotations

import json
import sys
import tempfile
import urllib.request
from urllib.parse import quote, urlencode

from datetime import datetime, timezone
from pathlib import Path

AUTH = Path.home() / ".pi" / "agent" / "auth.json"
OUT = Path("/tmp/kindle-usage.json")
TIMEOUT = 10
GLM_URL = "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
GLM_USAGE_URL = "https://open.bigmodel.cn/api/monitor/usage/model-usage"
GO_URL = "https://opencode.ai/zen/go/v1/usage"
# GLM has no monthly token quota; the 30d bar is computed as tokens used in the
# calendar month vs Max-plan 30-day capacity. 613M/week is the official
# all-peak lower bound (docs.bigmodel.cn coding-plan overview); 30/7 scales it
# to a month. ponytail: fixed plan constant; derive per-level if tier changes.
GLM_MONTHLY_CAPACITY = 613_000_000 * 30 / 7


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


def glm_monthly_tokens(key: str, start_ms: int, attempts: int = 3) -> int | None:
    """Sum tokens since start_ms; None if the API keeps serving stale caches.

    model-usage intermittently returns a cached series for the wrong range
    (observed: full history with a tiny tail), which would silently understate
    the bar. A valid response's first bucket sits at the requested start; a
    36h tolerance absorbs the daily/hourly and Beijing-time bucket offsets.
    """
    fmt = "%Y-%m-%d %H:%M:%S"
    start = datetime.fromtimestamp(start_ms / 1000, tz=timezone.utc).strftime(fmt)
    end = datetime.now(timezone.utc).strftime(fmt)
    query = urlencode({"startTime": start, "endTime": end}, quote_via=quote)
    for _ in range(attempts):
        try:
            data = (get_json(f"{GLM_USAGE_URL}?{query}", key).get("data") or {})
            buckets = data.get("x_time") or []
            if buckets:
                first = str(buckets[0])[:16]
                parsed = datetime.fromisoformat(first).timestamp() * 1000
                if abs(parsed - start_ms) <= 36 * 3600 * 1000:
                    return sum(data.get("tokensUsage") or [])
        except (KeyError, ValueError, OSError):
            pass  # retry; a None return renders as "U -" rather than a lie
    return None


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
        # TIME_LIMIT is the monthly MCP-call quota, not tokens; kept only as the
        # real monthly cycle boundary anchor for the computed 30d token window.
        monthly_cycle = find("TIME_LIMIT", 5)
        monthly = {}
        reset_ms = epoch_ms(monthly_cycle.get("nextResetTime"))
        if reset_ms:
            start_ms = reset_ms - 30 * 24 * 60 * 60 * 1000
            used = glm_monthly_tokens(key, start_ms)
            monthly = {
                "percentage": None if used is None else round(used / GLM_MONTHLY_CAPACITY * 100),
                "resetMs": reset_ms,
            }
        return {
            "fiveHour": window(five_hour.get("percentage"), five_hour.get("nextResetTime")),
            "weekly": window(weekly.get("percentage"), weekly.get("nextResetTime")),
            "monthly": monthly,
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
        windows = {}
        for name in ("rolling", "weekly", "monthly"):
            item = usage.get(name) or {}
            # Only trust percent when the window reports healthy; a degraded
            # window renders as "U -" rather than a possibly-stale number.
            windows[name] = window(
                item.get("percent") if item.get("status") == "ok" else None,
                item.get("resetsAt"),
            )
        return windows
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
