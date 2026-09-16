# Gateway load probe

Two tools measure the MCP gateway under concurrency. They answer different
questions and only one of them is a gate.

| Command | From | Answers |
| --- | --- | --- |
| `mix soak` | `ptc_gateway/` | Do the ceilings hold, is every slot returned, does a call leave anything behind? Asserted. |
| `mix run bench/gateway_load.exs` | `ptc_gateway/` | How fast is it, where does it stop scaling, and which owner is the ceiling? Reported. |

`mix test` excludes `:soak`. Neither tool needs a network, a provider or a
credential beyond the fixture's own token.

## What the gate asserts

`ptc_gateway/test/gateway_load_test.exs` drives a real listener with concurrent
raw-socket clients. `PtcGatewayTest` already covers the contract one request at
a time; everything here needs requests to overlap.

- **Ceilings.** `max_inflight_requests` and `max_concurrent_runs` are asserted
  at the peak of a burst that fills them.
- **Slot return.** Every path that is not the happy one: saturation, a reset
  peer, a half-open peer, a reused connection, and a client that never finishes
  its request.
- **Residue.** A fitted byte slope over four batches of calls, because a
  per-call residue small enough to pass a single-cycle assertion is what
  accumulates over a host's lifetime. `PTC_GATEWAY_SOAK_CYCLES` sets the batch
  size.

## Read a ceiling from the owner, never from the client

A client timestamps a marker when its own process is scheduled to read the
socket, not when the server wrote it. Under a burst that jitter is most of the
measurement, and it inflates every interval in the same direction.

Both client-side readings were tried as ceilings here and both were wrong.
Sixty-four simultaneous calls against a bound of eight in-flight requests
produced twenty-three client intervals each spanning the same forty-six
milliseconds, because every one of them was sent at the same instant and
finished at the same instant whatever the server did in between. The same burst
against a run bound of two measured a peak of thirty-nine overlapping runs,
while `RunAdmission`'s own accounting never held more than one reservation.

So a ceiling is sampled from the owner that enforces it, and the client-side
overlap is reported beside it and asserted on nothing. The gap between the two
is worth reading: it is how much of a call's latency was waiting rather than
working.

A sampler can only under-report a peak it missed, which makes `peak <= bound`
sound and `peak == bound` a coin toss on a burst that clears in twenty
milliseconds. That the bound was *reached* is proved from the refusals instead —
a 429 is returned only when capacity is full — with the other bound configured
out of reach so the refusal is unambiguous.

## Two traps in the fixture

Contract compilation injects `additionalProperties: false`, so the default
`{"type": "object"}` schema accepts `{}` and nothing else. A call carrying a
payload against it returns a contract error inside an HTTP 200, and a test that
only checks the status will not notice. Declare the properties through
`GatewayFixture.fixture/3`'s `:schema` option.

The default workflow returns its input unchanged, in microseconds. That is too
fast to observe concurrently, which is what made the client-side reading
useless. `:body` replaces it with something slow enough to overlap.

## Reading the benchmark

`tools/list` does everything a call does except run a workflow — connection,
header validation, authentication, admission, dispatch, response — so its
plateau is the gateway's own cost. `tools/call` adds the run, and the gap
between the two is the workflow's.

The mailbox table names the ceiling. An owner whose mailbox stays at zero is not
the bottleneck however slow the endpoint looks; one whose depth grows with
concurrency is. Measured on a ten-scheduler darwin/arm64 machine, the trivial
echo workflow plateaus near 1,100 calls per second at concurrency 16, after
which latency grows linearly with no throughput gained, and `RunAdmission` is
the owner that queues — `RequestAdmission` stays near zero throughout.

Numbers are machine- and scheduler-specific, so a comparison is only meaningful
against another run on the same machine. There is no committed baseline.

## Operational properties this surfaced

A request holds one of `max_inflight_requests` from before its body is read
until the response completes, and Bandit waits 15 seconds for body bytes that
never arrive. So `max_inflight_requests` clients that send perfect headers and
no body starve the MCP endpoint for 15 seconds — while `/health/ready` keeps
returning 200, because readiness reports on the warm runtime rather than on
request admission. Both facts are asserted in
`gateway_load_test.exs`; the loopback binding and the bearer requirement are
what bound the exposure.

Connection reuse is worth roughly four times the throughput of one connection
per call at the same concurrency, so a client that opens a socket per tool call
is paying more for TCP than for the workflow.
