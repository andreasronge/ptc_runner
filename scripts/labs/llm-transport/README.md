# LLM transport baseline probe

Run from a prepared checkout in a fresh Mix VM:

```bash
mix run scripts/labs/llm-transport/run.exs /tmp/ptc-llm-baseline.json
```

Omit the output argument to print JSON. This maintainer probe loads shared
test fixtures, disables dependency dotenv loading, uses a dummy credential,
and sends requests only to its loopback server. It refuses an already-running
ReqLLM application because it owns this VM's provider configuration.

The probe configures one HTTP/1 Finch pool with two connections, warms the
prepared OpenRouter path, observes normal responses and Kernel budget
settlement, occupies both connections, and compares a queued request through
Dispatcher with a direct adapter call. Both carry a 250 ms LLM deadline.
It then kills the two holding callers, observes peer socket closure within
a shared one-second window, and sends recovery traffic. The direct call can
take Finch's default five-second checkout timeout, so a run takes several
seconds. Synchronization uses socket events and process monitors.

The JSON contains outcomes, latency samples, usage/reservation and ledger
projections, process/port snapshots, dependency versions, and source hashes.
An exception from the direct adapter is recorded by class without provider
text. Successful warmup, successful normal Kernel dispatch, and both holding
requests arriving are prerequisites; a failure there stops the probe.

This is a local characterization, not a performance acceptance benchmark.
The server closes successful connections and uses no TLS; it cannot measure
connection reuse, public HTTPS, sustained leaks, or whole-workflow capacity.
The observation windows are provisional diagnostic bounds. A direct adapter
deadline is not evidence about the Dispatcher-owned whole-call cutoff.
No runtime defaults are changed by adding this lab.

## Opt-in comparison

The experimental adapter lives only in this lab. It delegates preparation,
model metadata, and reservation pricing to the existing ReqLLM adapter;
it never changes the application's default. It requires the corrected
transport source on branch `codex/ptc-runner-pilot-parity` in the
`andreasronge/ptc_llm_http` repository. The evidence record pins the revision.
Published `0.1.0` lacks required fixes.

```bash
export PTC_LLM_HTTP_PATH=/absolute/path/to/ptc_llm_http-pilot
mix deps.get
mix compile
PTC_PILOT_REPORT=/tmp/ptc-pilot-comparison.json \
  mix run scripts/labs/llm-transport/compare.exs
```

Keep the path variable set for every Mix command in that build. Unset it,
then run `mix deps.get` and `mix compile` to return to the published pin.
Production builds ignore the override; the dependency remains dev/test-only.
The comparison uses no real credentials or public network. It fails on a
broken invariant; the optional JSON report contains diagnostic batch timings,
resource observations, and source identities. The report alone is not a test
pass: check the command exit status.

The same support-triage manifest runs through both adapters at concurrency
two, with two real Lisp tool round trips per fixture workflow. Tests cover
preparation rejection, required accounting, precise cost settlement, zero
versus absent usage, overruns, structured output, output-limit attribution,
physical capacity, active deadlines, owner failure, provider errors, and
repeated cancellation/readmission. One shared transport runtime has a global
and OpenRouter-group capacity of two and no waiting queue.

`ServingHost` recovers the minimal request-owner handoff from closed PR #1482
at `d752a5fd9`. A separate one-workflow admission owner rejects excess incoming
requests with 503, with no queue. Closing a real client socket kills the
workflow owner and closes its provider socket. Workflow admission is released
on owner death; the transport independently keeps physical capacity occupied
until cleanup finishes. This framing fixture is not an MCP implementation,
public server, authentication layer, or replacement for gateway conformance.

## Bounded live check

Use an explicit environment file, or an already configured
`OPENROUTER_API_KEY`. The probe does not print prompts, credentials, responses,
or provider error text. It sends one text call per adapter at a 512-token cap;
`PTC_PILOT_WORKFLOW=1` additionally runs the existing three-turn support-triage
workflow per adapter at its original 4096-token cap. These are billable calls.
The probe exits unsuccessfully if any call or workflow result fails.

```bash
PTC_PILOT_WORKFLOW=1 \
  mix run scripts/labs/llm-transport/live.exs /absolute/path/to/.env
```

The model is explicitly `openrouter:deepseek/deepseek-v4-flash`, matching the
manifest; `PTC_TEST_MODEL` does not select a different workload. An optional
`PTC_PILOT_ADAPTER=http` limits diagnostic reruns to the experimental adapter.
There is no retry or automatic transport fallback. Each text call has a
30-second deadline; the workflow retains its checked-in limits.

A live success verifies DNS/TLS and provider compatibility, not latency
acceptance. Generation varies between calls. The local fixture closes every
response, so neither probe establishes the cost of forfeiting pooled TLS
connection reuse under sustained traffic.
