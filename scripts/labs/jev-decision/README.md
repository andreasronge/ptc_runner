# Classify support tickets with Jev

Run one practical Jev decision from PTC-Lisp and get the refund-related ticket
IDs together with the probability behind every classification.

This source-checkout lab adapts `examples/support-triage/01-one-question`.
Add `OPENROUTER_API_KEY` to the repository `.env`, then run:

```sh
set -a
source .env
set +a
mix run scripts/labs/jev-decision/run-refund-triage.exs
```

The live result on 2026-09-19 selected the two refund tickets:

```json
{
  "model": "typesafe/jev-1.13-20260917",
  "refund_ticket_ids": ["T-1001", "T-1004"],
  "usage": {
    "cost": 0.000028014,
    "input_tokens": 667,
    "output_tokens": 130
  }
}
```

The command also prints all six boolean decisions. Jev assigned `0.99`
probability to each returned ticket and `0.01` to each remaining ticket in
that run. Probabilities, token use, cost, and the resolved model may change.

## Follow the program

[`decision.clj`](decision.clj) defines the small PTC-Lisp API:

```clojure
(decision/request {"state" state "questions" questions})
```

The refund workflow in [`support/lab.exs`](support/lab.exs) sends the six
tickets as state and asks one named boolean question for each ticket. All six
questions travel in one request. It then keeps answers whose probability is at
least `0.5`:

```clojure
(->> tickets
     (filter (fn [ticket]
               (>= (get-in answers [(get ticket "answer_id") "probability"]) 0.5)))
     (map (fn [ticket] (get ticket "ticket_id")))
     vec)
```

Jev owns the fuzzy text classification. PTC-Lisp owns the visible threshold
and result shape. This differs from the original support-triage example, where
a chat model writes a program that searches the tickets.

## Inspect the broader response shapes

Run the companion probe to see choice, score, and boolean answers together:

```sh
mix run scripts/labs/jev-decision/run.exs
```

The host pins `typesafe/jev-1.13`, keeps the credential outside Lisp, and
normalizes OpenRouter's `noul` wire response to `boolean` plus `probability`.

This remains a lab. `decision-request` is not yet a host-config provider, and
it does not yet participate in LLM replay, cost budgets, or admission. The
recommended product boundary is a separate `decision/request` prelude that
shares those host policies with `llm/request`.

## Supported boundary and private records

The lab accepts map state and named questions with nonempty string instructions.
Boolean questions may omit criteria or provide exactly `true` and `false` string
descriptions. Choice criteria contain 1–255 named string descriptions; score
criteria contain 2–10 ordered string levels. This string-only subset is a lab
restriction: the [vendor API](https://docs.typesafe.ai/api) also accepts
structured instructions and criteria and null choice descriptions.

Responses must answer every requested ID once with the corresponding wire type
(`noul`, `choice`, or `score`). Choice distributions cover exactly the requested
options; score distributions and legends cover exactly the requested levels.
Probabilities and confidence are finite values from 0 to 1. Distribution sums,
chosen-option ties, and reported weighted scores allow an absolute rounding
difference of at most `0.01`; larger differences fail validation. The raw
values are never repaired. Successful results retain full distributions,
confidence, score, and legend.

A boolean answer is a probability of yes, not a boolean decision. The refund
workflow applies its own `0.5` threshold. Confidence describes concentration
of a distribution; it does not establish calibration or correctness.

Every received successful HTTP response is recorded before answer validation.
The default recorder writes private Erlang term files under
`tmp/jev-decision-attempts/` with mode `0600`; callers can inject a `:recorder`
function for comparison runs. Each record contains the dispatched request, raw
response, resolved model, status, validation outcome, independently validated
usage and cost, and a bounded allowlist of available OpenRouter correlation or
retry headers (`x-generation-id`, `x-request-id`, `retry-after`). Those headers
are captured only if present; the Decisions endpoint does not promise them.
A malformed response returns a dispatched `invalid_result` error without
retry. Valid reported usage and cost remain known even when an answer is
rejected. Missing or malformed usage and absent cost are `:unknown`, so a
comparison harness can stop and retain its reservation. This lab recorder does
not settle Kernel LLM budgets or provide replay or admission. Transport retries
remain disabled and host execution limits still apply.
