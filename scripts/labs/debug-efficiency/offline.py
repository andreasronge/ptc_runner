#!/usr/bin/env python3
"""Score a frozen, synthetic debugging replay. Uses only Python's standard library."""

import argparse
import json
from pathlib import Path


def score_case(case, arm):
    truth = case["truth"]
    record = case["arms"][arm]
    attempts = record["attempts"]
    if arm == "fixed" and len(attempts) > 1:
        raise ValueError(f'{case["id"]}: fixed baseline allows one reasoning call')

    spent = 0
    unknown = 0
    dispatched = 0
    for attempt in attempts:
        if attempt["status"] not in ("accepted", "rejected", "failed", "predispatch"):
            raise ValueError(f'{case["id"]}: invalid attempt status')
        if attempt["status"] == "predispatch":
            if attempt["dispatched"] or attempt["cost_microusd"] != 0:
                raise ValueError(f'{case["id"]}: predispatch cannot incur spend')
        elif not attempt["dispatched"]:
            raise ValueError(f'{case["id"]}: received attempt must be dispatched')
        if attempt["dispatched"]:
            dispatched += 1
            if attempt["cost_microusd"] is None:
                unknown += 1
            elif isinstance(attempt["cost_microusd"], int) and attempt["cost_microusd"] >= 0:
                spent += attempt["cost_microusd"]
            else:
                raise ValueError(f'{case["id"]}: invalid cost')

    response = record.get("response")
    if any(a["status"] != "accepted" for a in attempts) and response is not None:
        raise ValueError(f'{case["id"]}: failed attempt cannot publish a response')
    if response is None:
        outcome = "failure"
    elif response["decision"] == "abstain" and response.get("cause") is None and not response.get("evidence_ids"):
        outcome = "correct_abstention" if not truth["answerable"] and not truth.get("no_bug") else "abstention"
    elif response["decision"] == "no_bug" and response.get("cause") is None:
        cited = response.get("evidence_ids", [])
        outcome = ("correct_no_bug" if truth.get("no_bug") and cited and
                   set(truth["required_evidence_ids"]).issubset(cited) and
                   set(cited).issubset(case["evidence"]) else "wrong")
    elif response["decision"] == "diagnose":
        cited = response.get("evidence_ids", [])
        available = case["evidence"].keys()
        if not cited or not set(cited).issubset(available):
            outcome = "unsupported"
        elif not truth["answerable"]:
            outcome = "wrong"
        elif response.get("cause") == truth["cause"] and set(truth["required_evidence_ids"]).issubset(cited):
            outcome = "correct"
        else:
            outcome = "wrong"
    else:
        outcome = "invalid_response"

    return {"id": case["id"], "outcome": outcome, "attempts": len(attempts),
            "dispatched": dispatched, "known_cost_microusd": spent,
            "unknown_cost_attempts": unknown}


def run(data):
    ids = [case["id"] for case in data["cases"]]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate case id")
    result = {}
    for arm in ("deterministic", "fixed"):
        rows = [score_case(case, arm) for case in data["cases"]]
        result[arm] = {
            "cases": len(rows),
            "outcomes": {name: sum(row["outcome"] == name for row in rows)
                         for name in ("correct", "correct_no_bug", "wrong", "unsupported",
                                      "abstention", "correct_abstention", "failure", "invalid_response")},
            "answered_coverage": sum(row["outcome"] in ("correct", "correct_no_bug", "wrong", "unsupported") for row in rows),
            "attempts": sum(row["attempts"] for row in rows),
            "dispatched": sum(row["dispatched"] for row in rows),
            "known_cost_microusd": sum(row["known_cost_microusd"] for row in rows),
            "unknown_cost_attempts": sum(row["unknown_cost_attempts"] for row in rows),
            "total_cost_known": all(row["unknown_cost_attempts"] == 0 for row in rows),
            "rows": rows,
        }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    args = parser.parse_args()
    print(json.dumps(run(json.loads(args.fixture.read_text())), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
