#!/usr/bin/env python3
"""Render GLM CN and OpenCode Go quotas in a Kindle-sized token dashboard.

The visual layout borrows the reference Kindle dashboard: title and timestamp,
a heavy rule, bordered provider cards, black usage fills, gray time markers,
and reset labels. The working canvas is 800x600 landscape and is rotated to a
600x800 Kindle PNG by default.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

CANVAS_W, CANVAS_H = 800, 600
BG, FG, MUTED, RULE = 255, 0, 90, 190
USAGE_STORE = Path("/tmp/kindle-usage.json")
FONT_REGULAR = "/System/Library/Fonts/HelveticaNeue.ttc"
FONT_BOLD = "/System/Library/Fonts/HelveticaNeue.ttc"

MARGIN = 20
CARD_GAP = 20
HEADER_RULE_Y = 74
CARD_Y = 94
CARD_BOTTOM = CANVAS_H - MARGIN
CARD_H = CARD_BOTTOM - CARD_Y
CARD_W = (CANVAS_W - 2 * MARGIN - CARD_GAP) // 2


def font(path: str, size: int):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


def load_usage(path: Path = USAGE_STORE) -> dict:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def format_percent(value) -> str:
    if value is None:
        return "-"
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "-"
    return f"{int(round(number))}%"


def numeric_percent(value) -> float | None:
    try:
        return max(0.0, min(100.0, float(value)))
    except (TypeError, ValueError):
        return None


def format_reset(reset_ms) -> str:
    try:
        return datetime.fromtimestamp(float(reset_ms) / 1000).astimezone().strftime("%d/%m/%Y %H:%M")
    except (TypeError, ValueError, OverflowError, OSError):
        return "-"


def time_progress(reset_ms, duration_seconds: int, now_ms=None) -> float | None:
    """Return elapsed percentage for a window ending at reset_ms."""
    if reset_ms is None or duration_seconds <= 0:
        return None
    try:
        reset = float(reset_ms)
        now = time.time() * 1000 if now_ms is None else float(now_ms)
    except (TypeError, ValueError):
        return None
    # ponytail: infer the start from the displayed 5h/7d/30d duration; exact
    # rolling/calendar-window starts would require provider start timestamps.
    duration_ms = duration_seconds * 1000
    return max(0.0, min(100.0, (now - (reset - duration_ms)) / duration_ms * 100.0))


def truncate(draw: ImageDraw.ImageDraw, text: str, text_font, max_width: int) -> str:
    if draw.textlength(text, font=text_font) <= max_width:
        return text
    suffix = "..."
    while text and draw.textlength(text + suffix, font=text_font) > max_width:
        text = text[:-1]
    return text + suffix


def draw_progress(draw: ImageDraw.ImageDraw, x: int, y: int, width: int, height: int, percent: float | None, fill=FG, outline=FG) -> None:
    border = 3
    draw.rectangle((x, y, x + width, y + height), outline=outline, width=border)
    if percent is None or percent <= 0:
        return
    inner_width = width - 2 * border
    fill_width = round(inner_width * percent / 100)
    if fill_width:
        draw.rectangle(
            (x + border, y + border, x + border + fill_width - 1, y + height - border),
            fill=fill,
        )


def draw_time_marker(draw: ImageDraw.ImageDraw, x: int, y: int, width: int, height: int, percent: float | None) -> None:
    if percent is None:
        return
    border = 3
    marker_x = x + round((width - 2 * border) * percent / 100) + border
    marker_x = max(x + border, min(x + width - border, marker_x))
    # White halo keeps the gray marker visible when it falls inside the black usage fill.
    draw.rectangle((marker_x - 3, y, marker_x + 3, y + height), fill=BG)
    draw.rectangle((marker_x - 1, y, marker_x + 1, y + height), fill=MUTED)


def draw_reset(draw: ImageDraw.ImageDraw, x: int, y: int, reset_ms, regular, bold) -> None:
    prefix = "Resets: "
    value = format_reset(reset_ms)
    draw.text((x, y), prefix, font=regular, fill=FG)
    prefix_width = draw.textlength(prefix, font=regular)
    draw.text((x + prefix_width, y), value, font=bold, fill=FG)


def draw_card(draw: ImageDraw.ImageDraw, x: int, y: int, width: int, height: int, title: str, provider: dict, title_font, label_font, metric_font, legend_font, regular, bold) -> None:
    draw.rectangle((x, y, x + width, y + height), outline=FG, width=4)
    pad = 18
    draw.text((x + pad, y + 14), title, font=title_font, fill=FG)
    legend = "U=used  T=time"
    legend_width = draw.textlength(legend, font=legend_font)
    draw.text((x + width - pad - legend_width, y + 24), legend, font=legend_font, fill=MUTED)
    draw.line((x + pad, y + 58, x + width - pad, y + 58), fill=FG, width=2)

    error = provider.get("error") if isinstance(provider, dict) else "unavailable"
    if error:
        draw.text((x + pad, y + 86), "! unavailable", font=label_font, fill=FG)
        message = truncate(draw, str(error), regular, width - 2 * pad)
        draw.text((x + pad, y + 120), message, font=regular, fill=MUTED)
        return

    windows = (
        ("5h", "fiveHour", 5 * 60 * 60),
        ("7d", "weekly", 7 * 24 * 60 * 60),
        ("30d", "monthly", 30 * 24 * 60 * 60),
    )
    if title == "OpenCode Go":
        windows = (
            ("5h", "rolling", 5 * 60 * 60),
            ("7d", "weekly", 7 * 24 * 60 * 60),
            ("30d", "monthly", 30 * 24 * 60 * 60),
        )

    row_x = x + pad
    row_width = width - 2 * pad
    row_y = y + 78
    row_step = 124
    for label, key, duration_seconds in windows:
        item = provider.get(key) or {}
        percent = numeric_percent(item.get("percentage"))
        elapsed = time_progress(item.get("resetMs"), duration_seconds)
        draw.text((row_x, row_y), label, font=label_font, fill=FG)
        metrics = f"U {format_percent(item.get('percentage'))}  T {format_percent(elapsed)}"
        metrics_width = draw.textlength(metrics, font=metric_font)
        draw.text((row_x + row_width - metrics_width, row_y + 2), metrics, font=metric_font, fill=FG)
        draw_progress(draw, row_x, row_y + 30, row_width, 26, percent)
        draw_time_marker(draw, row_x, row_y + 30, row_width, 26, elapsed)
        draw_reset(draw, row_x, row_y + 66, item.get("resetMs"), regular, bold)
        row_y += row_step


def render(usage: dict, output: Path, rotation: int = 270) -> None:
    image = Image.new("L", (CANVAS_W, CANVAS_H), BG)
    draw = ImageDraw.Draw(image)

    title_font = font(FONT_BOLD, 34)
    stamp_font = font(FONT_REGULAR, 18)
    card_title_font = font(FONT_BOLD, 28)
    label_font = font(FONT_BOLD, 20)
    metric_font = font(FONT_BOLD, 16)
    legend_font = font(FONT_REGULAR, 13)
    regular = font(FONT_REGULAR, 17)
    bold = font(FONT_BOLD, 17)

    draw.text((MARGIN, 18), "Token Dashboard", font=title_font, fill=FG)
    stamp = datetime.now().astimezone().strftime("%d/%m/%Y %H:%M")
    stamp_width = draw.textlength(stamp, font=stamp_font)
    draw.text((CANVAS_W - MARGIN - stamp_width, 30), stamp, font=stamp_font, fill=FG)
    draw.line((MARGIN, HEADER_RULE_Y, CANVAS_W - MARGIN, HEADER_RULE_Y), fill=FG, width=6)

    glm = usage.get("glm") or {"error": "no usage data"}
    go = usage.get("go") or {"error": "no usage data"}
    draw_card(draw, MARGIN, CARD_Y, CARD_W, CARD_H, "GLM Coding (CN)", glm, card_title_font, label_font, metric_font, legend_font, regular, bold)
    draw_card(draw, MARGIN + CARD_W + CARD_GAP, CARD_Y, CARD_W, CARD_H, "OpenCode Go", go, card_title_font, label_font, metric_font, legend_font, regular, bold)

    if rotation not in (0, 90, 180, 270):
        raise ValueError("rotation must be 0, 90, 180, or 270")
    if rotation:
        image = image.rotate(rotation, expand=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output, "PNG", optimize=True)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--output", default="/tmp/kindle-usage-dashboard.png")
    parser.add_argument("--usage", default=str(USAGE_STORE))
    parser.add_argument(
        "--rotation",
        type=int,
        choices=(0, 90, 180, 270),
        default=int(os.environ.get("KINDLE_USAGE_ROTATION", "270")),
        help="rotation applied after rendering the 800x600 layout (default: 270)",
    )
    args = parser.parse_args(argv[1:])
    render(load_usage(Path(args.usage)), Path(args.output), args.rotation)
    print(f"wrote {args.output} (rotation={args.rotation})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
