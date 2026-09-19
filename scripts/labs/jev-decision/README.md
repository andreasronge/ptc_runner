# Jev decision lab

This lab runs a batched Jev evaluation through the PtcRunner Kernel. Its local
`decision/request` prelude wraps a read-only `decision-request` capability. The
host pins `typesafe/jev-1.13`, owns the OpenRouter credential, converts the
provider's `noul` wire type to a provider-neutral `boolean`, and returns the
resolved model, named answers, confidence/probability data, and usage.

From the repository root:

```sh
set -a
source .env
set +a
mix run scripts/labs/jev-decision/run.exs
```

The example submits choice, score, and boolean questions in one request. It
prints only the normalized result; the API key and raw provider response never
cross into Lisp.

## Observed live result

On 2026-09-19, OpenRouter resolved the pinned alias to
`typesafe/jev-1.13-20260917`. In the bundled support-ticket example it selected
`billing` with confidence `1.0`, scored severity `1.33` with confidence `0.6`,
and assigned `0.88` probability to same-day urgency. The batched call used 415
input tokens and 68 output tokens and reported a cost of `$0.00001743`.

## Boundary recommendation

Keep decisions separate from `llm/request`. That existing function represents
generation: messages, tools, text, and structured output. Jev evaluates state
against several named questions and returns calibrated answers rather than a
generated message. Reusing `llm/request` would require a second incompatible
request and response contract behind one name.

The thin prelude is still worthwhile. `decision/request` gives PTC-Lisp a
stable, discoverable namespace while the host capability owns model selection,
authentication, validation, and provider adaptation. Once a ReqLLM release
contains its merged OpenRouter evaluation adapter, the callback can replace the
temporary direct `Req.post/2` call with `ReqLLM.evaluate/4`; the Lisp API and
normalized result can remain unchanged.

This is intentionally a lab, not a production provider installation. The
direct callback does not yet participate in PtcRunner's LLM admission,
reservation, replay, cost-budget, deadline, or private-inspection policies.
Those contracts should be designed before exposing decision models through a
host manifest.
