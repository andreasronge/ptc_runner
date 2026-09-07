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

Evidence capture requires a clean root checkout. The comparison additionally
requires a clean upstream checkout when `PTC_PILOT_REPORT` is set; both are
checked again before writing the report. Commit changes before recording
acceptance evidence. Omit `PTC_PILOT_REPORT` for ordinary local comparison tests.
Historical reports without this check are diagnostic observations only.

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

Both comparison and live probes reject a missing/empty path or unavailable
required APIs before issuing requests. Keep the path variable set for every
Mix command in that build. Unset it,
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

`ServingHost` exercises the request-owner handoff considered in closed PR
#1482 at `d752a5fd9`, using the current `RunAdmission.execute/5` lifecycle.
The request worker prepares, executes, and publishes before it returns a JSON
result. The connection stays responsive to disconnect, and the existing
internal `BoundedWorker` guards cover connection death and request timeout.
There is no independent workflow slot counter: execution admission remains
occupied through provider cleanup. Excess executions return HTTP 503 before
provider acquisition. Failures return fixed error codes without diagnostic
payloads; successful responses contain the published workflow value.

For each adapter, real socket tests cover success/readmission, overload,
disconnect while a provider closer is held, connection-process death,
request-worker death, timeout, and cleanup failure fencing future requests.
The regression first demonstrated that the former SSE “complete” response
omitted the workflow value. The loopback server uses one response per
connection. It still compiles per request and installs the same custom inline
capability as the baseline, not a shipped host installation. Ingress admission,
compile-once serving, MCP framing/conformance, authentication, and sustained
TLS/reuse measurements remain outside this fixture. Neither it nor its use of
an internal worker helper is a deployable gateway API.

Run the cold success case alone in a fresh VM so earlier tests cannot warm
model metadata or bundle compilation and hide request heap failures:

```bash
mix run -e 'Code.require_file("scripts/labs/llm-transport/compare.exs"); ExUnit.configure(exclude: [:test], include: [:http_cold_start])'
```

Repeat in another fresh VM with `:http_cold_timeout` instead of
`:http_cold_start`. Keep `PTC_LLM_HTTP_PATH` set as above. These checks caught
an undersized request-worker heap budget that the warmed suite masked. The
lab now allows 32 million heap words for preparation/execution/publication;
the Kernel's workflow and provider heap limits remain separate. This is a
provisional lab budget, not a deployment capacity recommendation. A separate
regression checks that refused preparations are closed while their caller
remains alive, rather than depending on disposable-worker exit for cleanup.

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
