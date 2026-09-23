# Offline debugging comparison check

This is a synthetic contract and accounting check for [the proposed comparison](../../../docs/research/debug-efficiency.md). It makes no provider request and contains no measured model result.

Run `python3 scripts/labs/debug-efficiency/offline.py scripts/labs/debug-efficiency/fixture.json`. The fixture uses one common `evidence` map per incident. The deterministic arm makes no request; the fixed arm has at most one recorded reasoning attempt. A response is `diagnose` with a cause and evidence IDs, `no_bug` with evidence IDs, or `abstain` with no cause or citations. The host owns evidence IDs and truth; it does not accept model confidence as a label. A diagnosis is correct only when its exact cause and required evidence IDs agree with the independent label. An uncited diagnosis is `unsupported` and counts as wrong in a future quality comparison. A diagnosis on an unanswerable case is wrong. A no-bug case needs affirmative evidence; abstaining on it does not score correct.

Every attempted dispatch has an explicit status and cost. A rejected response with known usage costs money and scores as failure. A failed dispatch with unknown usage keeps `total_cost_known: false`; the known subtotal is not a total or zero-cost estimate. A predispatch refusal costs zero and remains a failure. The fixture deliberately exercises all three. There are no retries in this replay. Its synthetic amounts and outputs demonstrate arithmetic only.

The input is intentionally small and self-contained. The live experiment will need a separate frozen issue, actual private capture authorization, provider recording, cap enforcement before dispatch, and live timing. This script cannot measure latency or establish Jev accuracy.
