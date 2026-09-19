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
(->> ticket-ids
     (filter (fn [ticket-id]
               (>= (get-in answers [ticket-id "probability"]) 0.5)))
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
