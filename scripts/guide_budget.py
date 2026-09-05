#!/usr/bin/env python3
"""Guide budget ratchet.

Guides are short end-user workflows that show one useful path and link to
reference pages for exhaustive detail (docs/maintainers/documentation.md). That
rule is easy to state and easy to erode: a bug fix adds one correct paragraph to
a guide, the next fix adds another, and six weeks later the page nobody could
skim is the page every new reader starts on.

This gate measures four properties per guide and fails when any of them exceeds
the committed baseline. It never fails on the existing backlog, so it can land
without a rewrite, and it cannot be satisfied by moving text between guides.

  words     total words, including code fences
  density   inline `identifiers` per 100 words of prose, code fences excluded.
            A guide sits well below the reference tier; crossing it means the
            page has become a reference wearing a guide's heading.
  blockers  paragraphs of 3+ sentences and 55+ words carrying no list, code, or
            table. These are what a hurried reader cannot skim past.
  tics      intensifiers (deliberately, explicitly, ...), the "X, not Y"
            contrast, and em-dashes per 100 words of prose. Each is harmless
            once; together they are the sound of text pasted in a paragraph
            at a time.

Usage:
  scripts/guide_budget.py check   [baseline.json]
  scripts/guide_budget.py bless   [baseline.json]
  scripts/guide_budget.py report  [baseline.json]
"""

from __future__ import annotations

import json
import os
import re
import sys

# Overridable so the gate's own regression test can point it at a fixture tree.
GUIDE_GLOB_DIRS = tuple(
    part
    for part in os.environ.get("PTC_GUIDE_DIRS", "docs/guides").split(os.pathsep)
    if part
)

# Caps for a guide with no baseline row. A new guide starts inside the budget
# rather than setting its own, so adding a page cannot quietly raise the bar.
NEW_GUIDE_CAPS = {"words": 700, "density": 5.0, "blockers": 2, "tics": 1.0}

METRICS = ("words", "density", "blockers", "tics")

FENCE = re.compile(r"```.*?```", re.S)
INLINE_CODE = re.compile(r"`[^`\n]+`")
SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)
TIC_WORDS = re.compile(
    r"\b(deliberately|explicitly|genuinely|simply|merely|robust(?:ly)?"
    r"|seamless(?:ly)?|leverages?|importantly|crucially|notably)\b",
    re.I,
)
TIC_CONTRAST = re.compile(r",\s+not\s+\S")
TIC_DASH = re.compile("\u2014")


def guide_paths() -> list[str]:
    found: list[str] = []
    for directory in GUIDE_GLOB_DIRS:
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            if name.endswith(".md"):
                found.append(os.path.join(directory, name))
    return found


def measure(path: str) -> dict:
    raw = open(path, encoding="utf-8").read()
    raw = HTML_COMMENT.sub("", raw)
    words = len(raw.split())

    prose = FENCE.sub("\n\n", raw)
    prose_words = len(prose.split()) or 1
    identifiers = len(INLINE_CODE.findall(prose))
    density = identifiers * 100.0 / prose_words

    plain = INLINE_CODE.sub(" ", prose)
    tics = (
        len(TIC_WORDS.findall(plain))
        + len(TIC_CONTRAST.findall(plain))
        + len(TIC_DASH.findall(plain))
    )

    blockers = 0
    for para in re.split(r"\n\s*\n", prose):
        flat = " ".join(para.split())
        if not flat:
            continue
        if flat[0] in "#|-*>" or flat.startswith("!["):
            continue
        sentences = [s for s in SENTENCE_SPLIT.split(flat) if len(s.split()) > 2]
        if len(sentences) >= 3 and len(flat.split()) >= 55:
            blockers += 1

    return {
        "words": words,
        "density": round(density, 1),
        "blockers": blockers,
        "tics": round(tics * 100.0 / prose_words, 1),
    }


def load_baseline(path: str) -> dict:
    if not os.path.exists(path):
        return {"guides": {}}
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def write_baseline(path: str, guides: dict) -> None:
    document = {
        "_comment": (
            "Guide budget ratchet. Regenerate with `scripts/guide_budget.sh bless` "
            "and explain the change in the commit body. See "
            "docs/maintainers/guide-budget.md."
        ),
        "new_guide_caps": NEW_GUIDE_CAPS,
        "guides": dict(sorted(guides.items())),
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=False)
        handle.write("\n")


def check(baseline_path: str) -> int:
    baseline = load_baseline(baseline_path)
    rows = baseline.get("guides", {})
    caps = baseline.get("new_guide_caps", NEW_GUIDE_CAPS)

    failures: list[str] = []
    slack: list[str] = []

    for path in guide_paths():
        current = measure(path)
        allowed = rows.get(path)
        unbaselined = allowed is None
        if unbaselined:
            allowed = caps

        for metric in METRICS:
            have = current[metric]
            cap = allowed.get(metric, caps[metric])
            if have > cap:
                origin = "new-guide cap" if unbaselined else "baseline"
                failures.append(
                    f"  {path}: {metric} {have} exceeds {origin} {cap}"
                )

        if not unbaselined:
            shrunk = [
                metric
                for metric in METRICS
                if current[metric] < allowed.get(metric, caps[metric])
            ]
            if shrunk:
                slack.append(
                    "  %s: %s"
                    % (
                        path,
                        ", ".join(
                            f"{m} {allowed.get(m, caps[m])} -> {current[m]}"
                            for m in shrunk
                        ),
                    )
                )

    if failures:
        print("guide budget: a guide grew past its budget.\n", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        print(
            "\nGuides show one useful path and link to a reference page for the"
            "\ndetail (docs/maintainers/documentation.md). Move the new prose into"
            "\nthe reference page that owns the surface and leave a link behind."
            "\nIf the guide genuinely needs it, run `scripts/guide_budget.sh bless`"
            "\nand say why in the commit body.",
            file=sys.stderr,
        )
        return 1

    print(f"guide budget: {len(guide_paths())} guides within budget.")
    if slack:
        print("\nBudget now loose enough to tighten (bless to lock the win in):")
        print("\n".join(slack))
    return 0


def bless(baseline_path: str) -> int:
    guides = {path: measure(path) for path in guide_paths()}
    write_baseline(baseline_path, guides)
    print(f"guide budget: recorded {len(guides)} guides in {baseline_path}")
    return 0


def report(baseline_path: str) -> int:
    baseline = load_baseline(baseline_path).get("guides", {})
    print(
        "%-42s %6s %8s %9s %6s"
        % ("guide", "words", "density", "blockers", "tics")
    )
    total = 0
    for path in guide_paths():
        current = measure(path)
        total += current["words"]
        allowed = baseline.get(path)
        flag = ""
        if allowed:
            over = [
                m
                for m in METRICS
                if current[m] > allowed.get(m, NEW_GUIDE_CAPS[m])
            ]
            flag = "  OVER: " + ",".join(over) if over else ""
        else:
            flag = "  (no baseline row)"
        print(
            "%-42s %6d %8.1f %9d %6.1f%s"
            % (
                os.path.basename(path),
                current["words"],
                current["density"],
                current["blockers"],
                current["tics"],
                flag,
            )
        )
    print("%-42s %6d" % ("TOTAL", total))
    return 0


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    baseline_path = sys.argv[2] if len(sys.argv) > 2 else ".guide-budget-baseline.json"
    if mode == "check":
        return check(baseline_path)
    if mode == "bless":
        return bless(baseline_path)
    if mode == "report":
        return report(baseline_path)
    print(f"unknown mode {mode!r}; use check, bless, or report", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
