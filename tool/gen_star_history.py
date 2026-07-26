#!/usr/bin/env python3
"""Generate a self-hosted star-history chart (docs/star-history.svg).

Why self-hosted rather than star-history.com or starchart.cc:

  * star-history.com refuses these repos outright — it answers
    "GitHub restricted starred-data access for openstrap/edge".
  * starchart.cc rate-limits anonymous callers, so the image intermittently
    renders as a broken graphic.
  * Both would make every visitor's browser call a third party. GitHub proxies
    README images through camo so it wouldn't leak there, but the landing page
    has no such protection, and "your data stays on your phone" reads poorly
    next to an analytics-capable third-party request on our own site.

So: fetch the stargazer timestamps ourselves, emit a plain SVG with no scripts
and no external references, and refresh it on a schedule
(.github/workflows/star-history.yml).

Usage:  GITHUB_TOKEN=... python3 tool/gen_star_history.py
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone

REPOS = ["OpenStrap/edge", "OpenStrap/protocol", "OpenStrap/analytics"]
OUT = "docs/star-history.svg"

W, H = 760, 300
PAD_L, PAD_R, PAD_T, PAD_B = 52, 16, 18, 34

# Colour-blind-safe, and legible on both themes.
SERIES_COLOURS = ["#e2825f", "#6aa9e0", "#7bbf8f"]


def gh(path):
    """Call the GitHub API via `gh`, which already holds credentials."""
    out = subprocess.run(
        ["gh", "api", path, "-H", "Accept: application/vnd.github.star+json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise RuntimeError(f"gh api {path} failed: {out.stderr.strip()[:200]}")
    return json.loads(out.stdout)


def stargazer_dates(repo):
    """Every starred_at, oldest first. Paginates until exhausted."""
    dates, page = [], 1
    while True:
        batch = gh(f"repos/{repo}/stargazers?per_page=100&page={page}")
        if not batch:
            break
        for s in batch:
            ts = s.get("starred_at")
            if ts:
                dates.append(datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                             .replace(tzinfo=timezone.utc))
        if len(batch) < 100:
            break
        page += 1
    dates.sort()
    return dates


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def build_svg(series):
    """series: list of (label, [datetime, ...]) oldest-first."""
    non_empty = [(l, d) for l, d in series if d]
    if not non_empty:
        raise SystemExit("no stargazer data")

    t_min = min(d[0] for _, d in non_empty)
    t_max = max(d[-1] for _, d in non_empty)
    span = max((t_max - t_min).total_seconds(), 1)
    y_max = max(len(d) for _, d in non_empty)
    # Round the axis up to something tidy.
    step = 10 ** max(0, len(str(y_max)) - 2)
    y_top = ((y_max // (step * 5)) + 1) * step * 5

    def px(t):
        return PAD_L + (t - t_min).total_seconds() / span * (W - PAD_L - PAD_R)

    def py(n):
        return H - PAD_B - (n / y_top) * (H - PAD_T - PAD_B)

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
        f'viewBox="0 0 {W} {H}" role="img" aria-label="Star history">',
        "<style>"
        ".bg{fill:#ffffff}.grid{stroke:#e2e2e2}.tick{fill:#5a5a5a}"
        ".ttl{fill:#1a1a1a}.lgd{fill:#1a1a1a}"
        "@media (prefers-color-scheme:dark){"
        ".bg{fill:#17161a}.grid{stroke:#333238}.tick{fill:#a3a3a8}"
        ".ttl{fill:#ececec}.lgd{fill:#ececec}}"
        "text{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Inter,"
        "Roboto,Helvetica,Arial,sans-serif}"
        "</style>",
        f'<rect class="bg" width="{W}" height="{H}" rx="10"/>',
    ]

    # Horizontal grid + y labels.
    for i in range(6):
        n = y_top * i // 5
        y = py(n)
        parts.append(f'<line class="grid" x1="{PAD_L}" y1="{y:.1f}" '
                     f'x2="{W - PAD_R}" y2="{y:.1f}" stroke-width="1"/>')
        parts.append(f'<text class="tick" x="{PAD_L - 8}" y="{y + 4:.1f}" '
                     f'font-size="11" text-anchor="end">{n}</text>')

    # X labels: first and last month.
    for t, anchor, x in ((t_min, "start", PAD_L), (t_max, "end", W - PAD_R)):
        parts.append(f'<text class="tick" x="{x}" y="{H - 12}" font-size="11" '
                     f'text-anchor="{anchor}">{t.strftime("%b %Y")}</text>')

    # Step lines — a star history is a step function, not a smooth curve.
    for idx, (label, dates) in enumerate(non_empty):
        colour = SERIES_COLOURS[idx % len(SERIES_COLOURS)]
        d = [f"M {px(dates[0]):.1f} {py(0):.1f}"]
        for i, t in enumerate(dates, start=1):
            d.append(f"H {px(t):.1f} V {py(i):.1f}")
        d.append(f"H {px(t_max):.1f}")
        parts.append(f'<path d="{" ".join(d)}" fill="none" stroke="{colour}" '
                     f'stroke-width="2" stroke-linejoin="round"/>')

    # Legend, top-left inside the plot.
    for idx, (label, dates) in enumerate(non_empty):
        colour = SERIES_COLOURS[idx % len(SERIES_COLOURS)]
        ly = PAD_T + 10 + idx * 16
        parts.append(f'<rect x="{PAD_L + 8}" y="{ly - 8}" width="10" height="10" '
                     f'rx="2" fill="{colour}"/>')
        parts.append(f'<text class="lgd" x="{PAD_L + 24}" y="{ly + 1}" '
                     f'font-size="11.5">{esc(label)} · {len(dates)}</text>')

    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    parts.append(f'<text class="tick" x="{W - PAD_R}" y="{PAD_T + 3}" '
                 f'font-size="10" text-anchor="end">updated {stamp}</text>')
    parts.append("</svg>")
    return "\n".join(parts)


def main():
    series = []
    for repo in REPOS:
        try:
            dates = stargazer_dates(repo)
        except RuntimeError as e:
            print(f"warn: {e}", file=sys.stderr)
            continue
        series.append((repo.split("/")[1], dates))
        print(f"{repo}: {len(dates)} stars", file=sys.stderr)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write(build_svg(series) + "\n")
    print(f"wrote {OUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
