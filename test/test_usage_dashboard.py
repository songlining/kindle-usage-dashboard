#!/usr/bin/env python3
import importlib.util
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("kindle_usage_png", ROOT / "bin/kindle-usage-png.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)

sample = {
    "glm": {
        "fiveHour": {"percentage": 13, "resetMs": 1787018940183},
        "weekly": {"percentage": 20, "resetMs": 1787281235997},
        "monthly": {"percentage": 1, "resetMs": 1789354835998},
    },
    "go": {
        "rolling": {"percentage": 44, "resetMs": 1787022095169},
        "weekly": {"percentage": 26, "resetMs": 1787529600169},
        "monthly": {"percentage": 37, "resetMs": 1788989812169},
    },
}

with tempfile.TemporaryDirectory() as directory:
    landscape = Path(directory) / "landscape.png"
    portrait = Path(directory) / "portrait.png"
    renderer.render(sample, landscape, rotation=0)
    renderer.render(sample, portrait, rotation=270)

    assert Image.open(landscape).size == (800, 600)
    assert Image.open(portrait).size == (600, 800)
    assert sum(pixel < 128 for pixel in Image.open(landscape).getdata()) > 1000
    assert renderer.format_reset(1787018940183) != "-"

    reset = 1_000_000
    duration = 100_000
    assert renderer.time_progress(reset, duration, now_ms=reset - duration * 1000) == 0
    assert renderer.time_progress(reset, duration, now_ms=reset - duration * 500) == 50
    assert renderer.time_progress(reset, duration, now_ms=reset) == 100
    assert renderer.time_progress(None, duration, now_ms=reset) is None
    assert renderer.time_progress(reset, 0, now_ms=reset) is None

print("ok")
