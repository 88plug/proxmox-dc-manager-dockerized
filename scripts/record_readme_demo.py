#!/usr/bin/env python3
"""Capture the README demo master for this repo (skill: readme-demo).

4K Playwright capture of the real product flow against the local compose
stack: painted login page -> credentials -> dashboard hold. Pre-warms the
app in a throwaway context first so the recorded pass never films loaders.
Output: docs/demo-raw/readme-demo.webm (3840x2160, asserted).
"""
import subprocess
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

REPO = Path(__file__).resolve().parent.parent
RAW = REPO / "docs" / "demo-raw"
URL = "https://localhost:8443"
PASSWORD = "changeme"
W, H = 3840, 2160

RAW.mkdir(parents=True, exist_ok=True)
for old in RAW.glob("*.webm"):
    old.unlink()

with sync_playwright() as p:
    # --window-size + screen: Chromium's screencast otherwise delivers frames
    # smaller than the 4K viewport (measured 3200x1800) and Playwright pads
    # the video with grey bars.
    browser = p.chromium.launch(args=["--window-size=3900,2300"])

    # Pre-warm off-camera: prime PDM's static assets + API so the recorded
    # pass paints instantly and never shows a loader.
    warm = browser.new_context(ignore_https_errors=True)
    wp = warm.new_page()
    wp.goto(URL, wait_until="networkidle")
    wp.fill("input[type=password]", PASSWORD)  # username prefills to root
    wp.keyboard.press("Enter")
    wp.wait_for_timeout(6000)
    warm.close()

    ctx = browser.new_context(
        viewport={"width": W, "height": H},
        screen={"width": W, "height": H},
        device_scale_factor=1,
        record_video_dir=str(RAW),
        record_video_size={"width": W, "height": H},
        ignore_https_errors=True,
        color_scheme="dark",  # PDM's signature look; skill luma gates assume dark UI
    )
    page = ctx.new_page()
    page.goto(URL, wait_until="networkidle")
    page.wait_for_selector("input[type=password]")
    page.wait_for_timeout(2500)  # painted login page holds

    field = page.locator("input[type=password]")
    field.click()
    page.keyboard.type(PASSWORD, delay=140)  # human-speed typing on camera
    page.wait_for_timeout(500)
    page.keyboard.press("Enter")

    # Dashboard lands (pre-warmed: instant paint). Long READY hold on the
    # product proof UI - panels, gauges, task summary.
    page.wait_for_timeout(3500)
    page.mouse.move(1900, 1000)
    page.wait_for_timeout(9000)
    # Gentle scroll to show the lower dashboard panels, then settle.
    page.mouse.wheel(0, 900)
    page.wait_for_timeout(5000)
    page.mouse.wheel(0, -900)
    page.wait_for_timeout(9000)

    ctx.close()  # flushes the webm
    browser.close()

webm = max(RAW.glob("*.webm"), key=lambda f: f.stat().st_mtime)
target = RAW / "readme-demo.webm"
if webm != target:
    webm.rename(target)

probe = subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
     "stream=width,height", "-of", "csv=p=0", str(target)],
    capture_output=True, text=True, check=True,
).stdout.strip()
print(f"captured {target} geometry={probe}")
if probe != f"{W},{H}":
    sys.exit(f"FATAL: capture geometry {probe} != {W},{H}")
