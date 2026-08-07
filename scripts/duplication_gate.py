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
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def normalize(snippet):
    """Collapse whitespace so reformatting alone does not churn a fingerprint."""
    return re.sub(r"\s+", " ", snippet).strip()


def relpath(path):
    return os.path.relpath(path, ROOT) if os.path.isabs(path) else path


def fingerprint(clone):
    """Content+location key, deliberately excluding line numbers.

    Keeping lines out means unrelated edits above a clone do not re-key it.
    """
    parts = sorted(
        (relpath(fragment["file"]), normalize(snippet))
        for fragment, snippet in zip(clone["fragments"], clone["snippets"])
    )
    canonical = "\n\0".join(f"{path}\0{snippet}" for path, snippet in parts)
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]


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
    }


def is_remnant(entry, resolved):
    """True when this clone is a smaller leftover of one that just disappeared.

    Editing one copy of duplicated code re-keys it. That is a real change, but
    it is not *new* duplication as long as it spans the same files and did not
    grow, so it must not fail the build.
    """
    return any(
        other["files"] == entry["files"] and entry["mass"] <= other["mass"]
        for other in resolved.values()
    )


def load(path):
    with open(path) as handle:
        return json.load(handle)


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("check", "bless"):
        sys.exit(__doc__)
    mode, report_path, baseline_path = sys.argv[1:]

    current = {fingerprint(c): entry_of(c) for c in load(report_path)["clones"]}

    if mode == "bless":
        with open(baseline_path, "w") as handle:
            json.dump({"clones": dict(sorted(current.items()))}, handle, indent=2)
            handle.write("\n")
        print(f"duplication baseline written: {len(current)} accepted clones")
        return 0

    baseline = load(baseline_path)["clones"] if os.path.exists(baseline_path) else {}

    resolved = {k: v for k, v in baseline.items() if k not in current}
    added = {k: v for k, v in current.items() if k not in baseline}
    remnants = {k: v for k, v in added.items() if is_remnant(v, resolved)}
    added = {k: v for k, v in added.items() if k not in remnants}

    for key, entry in sorted(resolved.items()):
        print(f"resolved  {key}  {entry['describe']}")
    for key, entry in sorted(remnants.items()):
        print(f"shrunk    {key}  {entry['describe']}")
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
