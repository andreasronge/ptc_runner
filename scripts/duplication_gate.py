#!/usr/bin/env python3
"""Ratchet an ExDNA clone report against a committed baseline.

Invoked through scripts/duplication_gate.sh, which produces the report.

    duplication_gate.py check <report.json> <baseline.json>
    duplication_gate.py bless <report.json> <baseline.json>

`check` fails only on clones that are not already in the baseline, so an
existing backlog never blocks a build while newly introduced duplication does.
"""

import hashlib
import json
import os
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def relpath(path):
    return os.path.relpath(path, ROOT) if os.path.isabs(path) else path


def snippet_fingerprint(snippet):
    """Hash ExDNA's AST-rendered snippet without changing literal contents."""
    return hashlib.sha256(snippet.encode()).hexdigest()


def occurrences_of(clone):
    return sorted(
        [
            {
                "file": relpath(fragment["file"]),
                "snippet": snippet_fingerprint(snippet),
            }
            for fragment, snippet in zip(clone["fragments"], clone["snippets"])
        ],
        key=lambda occurrence: (occurrence["file"], occurrence["snippet"]),
    )


def fingerprint(clone):
    """AST-content+location key, deliberately excluding line numbers.

    Keeping lines out means unrelated edits above a clone do not re-key it.
    """
    canonical = json.dumps(
        {"type": clone["type"], "occurrences": occurrences_of(clone)},
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def describe(clone):
    locations = sorted(
        f"{relpath(f['file'])}:{f['line']}" for f in clone["fragments"]
    )
    return f"{clone['type']} mass={clone['mass']} " + " <-> ".join(locations)


def files_of(clone):
    """The set of files a clone spans, ignoring position and content."""
    return tuple(sorted({relpath(f["file"]) for f in clone["fragments"]}))


def entry_of(clone):
    return {
        "describe": describe(clone),
        "files": list(files_of(clone)),
        "mass": clone["mass"],
        "occurrences": occurrences_of(clone),
        "type": clone["type"],
    }


def occurrence_counts(entry):
    return Counter((item["file"], item["snippet"]) for item in entry["occurrences"])


def type_rank(clone_type):
    return {"type_i": 0, "type_ii": 1}.get(clone_type)


def remnant_score(current, previous):
    """Return an overlap score when current is provably decaying previous debt."""
    current_rank = type_rank(current.get("type"))
    previous_rank = type_rank(previous.get("type"))

    if current_rank is None or previous_rank is None or current_rank < previous_rank:
        return None
    if current["mass"] > previous["mass"]:
        return None
    if len(current["occurrences"]) > len(previous["occurrences"]):
        return None
    if not set(current["files"]).issubset(previous["files"]):
        return None

    overlap = sum((occurrence_counts(current) & occurrence_counts(previous)).values())
    return overlap if overlap > 0 else None


def match_remnants(added, resolved):
    """Conservatively pair changed clones one-to-one with their prior debt."""
    candidates = []

    for current_key, current in added.items():
        for previous_key, previous in resolved.items():
            score = remnant_score(current, previous)
            if score is not None:
                candidates.append((score, current_key, previous_key))

    matches = {}
    used_previous = set()

    for _score, current_key, previous_key in sorted(candidates, reverse=True):
        if current_key not in matches and previous_key not in used_previous:
            matches[current_key] = previous_key
            used_previous.add(previous_key)

    return matches


def load(path):
    with open(path) as handle:
        return json.load(handle)


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("check", "bless"):
        sys.exit(__doc__)
    mode, report_path, baseline_path = sys.argv[1:]

    current = {}

    for clone in load(report_path)["clones"]:
        key = fingerprint(clone)
        if key in current:
            raise ValueError(f"duplicate clone fingerprint in report: {key}")
        current[key] = entry_of(clone)

    if mode == "bless":
        with open(baseline_path, "w") as handle:
            json.dump({"clones": dict(sorted(current.items()))}, handle, indent=2)
            handle.write("\n")
        print(f"duplication baseline written: {len(current)} accepted clones")
        return 0

    baseline = load(baseline_path)["clones"] if os.path.exists(baseline_path) else {}

    resolved = {k: v for k, v in baseline.items() if k not in current}
    added = {k: v for k, v in current.items() if k not in baseline}
    remnant_matches = match_remnants(added, resolved)
    remnants = {k: v for k, v in added.items() if k in remnant_matches}
    added = {k: v for k, v in added.items() if k not in remnants}
    resolved = {k: v for k, v in resolved.items() if k not in remnant_matches.values()}

    for key, entry in sorted(resolved.items()):
        print(f"resolved  {key}  {entry['describe']}")
    for key, entry in sorted(remnants.items()):
        print(f"shrunk    {key}  from={remnant_matches[key]}  {entry['describe']}")
    for key, entry in sorted(added.items()):
        print(f"NEW       {key}  {entry['describe']}")

    print(
        f"\nduplication: baseline={len(baseline)} current={len(current)} "
        f"new={len(added)} shrunk={len(remnants)} resolved={len(resolved)}"
    )

    if added:
        print(
            "\nNew duplication introduced. Extract the shared logic, or — if the "
            "repetition is deliberate — add an `# ex_dna:disable-for-next-line` "
            "comment above one copy explaining why. Re-bless the baseline only "
            "for duplication you are accepting as debt.\n"
            "See docs/guides/duplication-gate.md."
        )
        return 1

    if resolved:
        print(
            "\nDuplication was removed. Run `scripts/duplication_gate.sh bless` "
            "to lock in the improvement."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
