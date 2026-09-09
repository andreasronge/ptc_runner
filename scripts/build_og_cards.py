#!/usr/bin/env python3
"""Renders the Open Graph link-preview cards under `site/og/`.

    scripts/build_og_cards.py            # rewrite every card
    scripts/build_og_cards.py --check    # fail if a card is out of date

The cards are committed as PNGs because that is what a link scraper fetches,
but a committed PNG has no source: change `--accent` in `site/style.css` and
every card would keep the old colour with nothing to notice it. So the palette
is read out of `style.css` and the mark geometry out of `ptc-runner-mark.svg`,
and this script is the only thing that writes `site/og/`. Editing a card means
editing CARDS below and running this again.

Cards use the dark palette deliberately. A social feed is overwhelmingly light,
so the dark card is the one that separates from its background.

Needs `rsvg-convert` (`brew install librsvg`). Text is rendered by fontconfig
at build time rather than embedded as outlines, so a machine without Helvetica
Neue will substitute a different face -- run `--check` after regenerating on an
unfamiliar machine.
"""

import argparse
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
STYLE = ROOT / "site" / "style.css"
MARK = ROOT / "site" / "ptc-runner-mark.svg"
OUT_DIR = ROOT / "site" / "og"

WIDTH, HEIGHT = 1200, 630
FONT = "Helvetica Neue, Helvetica, Arial, sans-serif"

# name -> (title lines, subtitle, title size, first baseline)
#
# Lines are broken by hand: a card is read at thumbnail size, so where the
# title wraps is a design decision and not something to leave to a measurer.
CARDS = {
    "ptcrunner": (
        ["Build loops that check", "their work and recover", "from evidence."],
        "Bounded programs, explicit limits, recorded evidence.",
        58,
        250,
    ),
    "tools-built-for-llms": (
        ["Tools built for LLMs,", "not for humans"],
        "A language, a runtime and preludes",
        70,
        300,
    ),
    "adaptive-parser-runtime": (
        ["One workflow,", "three bounded missions"],
        "Watch code move without authority moving with it.",
        64,
        290,
    ),
}


def dark_palette():
    """The `:root:not([data-theme="light"])` token block from style.css."""
    css = STYLE.read_text(encoding="utf-8")
    match = re.search(
        r':root:not\(\[data-theme="light"\]\)\s*\{(.*?)\}', css, re.DOTALL
    )
    if not match:
        sys.exit("could not find the dark token block in site/style.css")

    tokens = dict(re.findall(r"--([\w-]+):\s*([^;]+);", match.group(1)))
    wanted = ("bg", "text", "muted", "accent", "border")
    missing = [name for name in wanted if name not in tokens]
    if missing:
        sys.exit("site/style.css dark block is missing: %s" % ", ".join(missing))

    return {name: tokens[name].strip() for name in wanted}


def mark_group(ink, accent):
    """The brand mark, recoloured for a fixed background.

    The shipped mark picks its colours with a `prefers-color-scheme` query,
    which means nothing to a renderer with no display, so the strokes are
    resolved here instead of inherited.
    """
    svg = MARK.read_text(encoding="utf-8")
    widths = dict(
        re.findall(r"\.(\w+)\s*\{[^}]*?stroke-width:\s*(\d+)", svg, re.DOTALL)
    )
    paths = re.findall(r'<path class="(\w+)"[^>]*d="([^"]+)"', svg)
    if not paths or not widths:
        sys.exit("could not read the paths out of site/ptc-runner-mark.svg")

    stroke = {"parenthesis": ink, "arrow": accent}
    rendered = []
    for cls, d in paths:
        # The arrow has a corner where the head meets the shaft; the
        # parentheses are single curves and never need a join.
        join = ' stroke-linejoin="round"' if cls == "arrow" else ""
        rendered.append(
            '  <path fill="none" stroke="%s" stroke-linecap="round"%s'
            ' stroke-width="%s" d="%s"/>' % (stroke[cls], join, widths[cls], d)
        )

    return '<g transform="translate(86,64) scale(0.62)">\n%s\n</g>' % "\n".join(rendered)


def card_svg(lines, subtitle, size, first_baseline, palette, mark):
    step = int(size * 1.2)
    tspans = "\n    ".join(
        '<tspan x="86" y="%d">%s</tspan>' % (first_baseline + i * step, line)
        for i, line in enumerate(lines)
    )
    rule_y = first_baseline + (len(lines) - 1) * step + 56

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}">
  <rect width="{WIDTH}" height="{HEIGHT}" fill="{palette['bg']}"/>
  <rect x="0" y="0" width="10" height="{HEIGHT}" fill="{palette['accent']}"/>
  {mark}
  <text x="160" y="112" font-family="{FONT}" font-size="30" font-weight="600" fill="{palette['text']}">PtcRunner</text>
  <text font-family="{FONT}" font-size="{size}" font-weight="650" fill="{palette['text']}" letter-spacing="-1.6">
    {tspans}
  </text>
  <rect x="86" y="{rule_y}" width="72" height="4" fill="{palette['accent']}"/>
  <text x="86" y="{rule_y + 60}" font-family="{FONT}" font-size="29" fill="{palette['muted']}">{subtitle}</text>
  <line x1="86" y1="548" x2="1114" y2="548" stroke="{palette['border']}" stroke-width="1"/>
  <text x="86" y="586" font-family="{FONT}" font-size="24" fill="{palette['muted']}">ptc-runner.dev</text>
</svg>'''


def render(svg):
    with tempfile.NamedTemporaryFile("w", suffix=".svg") as handle:
        handle.write(svg)
        handle.flush()
        result = subprocess.run(
            ["rsvg-convert", "-w", str(WIDTH), "-h", str(HEIGHT), handle.name],
            capture_output=True,
        )
    if result.returncode != 0:
        sys.exit("rsvg-convert failed: %s" % result.stderr.decode().strip())
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if any card differs from what this script renders",
    )
    args = parser.parse_args()

    if not subprocess.run(["which", "rsvg-convert"], capture_output=True).stdout:
        sys.exit("rsvg-convert not found; install it with `brew install librsvg`")

    palette = dark_palette()
    mark = mark_group(palette["text"], palette["accent"])
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    stale = []
    for name, (lines, subtitle, size, baseline) in sorted(CARDS.items()):
        png = render(card_svg(lines, subtitle, size, baseline, palette, mark))
        target = OUT_DIR / ("%s.png" % name)

        if args.check:
            current = target.read_bytes() if target.exists() else b""
            state = "ok" if current == png else "STALE"
            if current != png:
                stale.append(target.name)
        else:
            target.write_bytes(png)
            state = "wrote %d bytes" % len(png)

        print("%-28s %s" % (target.name, state))

    if stale:
        sys.exit(
            "\n%s out of date. Run scripts/build_og_cards.py and stage the result."
            % ", ".join(stale)
        )


if __name__ == "__main__":
    main()
