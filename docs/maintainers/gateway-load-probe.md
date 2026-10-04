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
- **Residue.** Tiered, because the metrics are not equally quiet. The process
  count returning exactly to its starting value is the gate that matters and has
  no noise at all. `:binary` and `:ets` carry a fitted byte slope against a
  512-byte threshold; their spread was within ±60 bytes per call over thirteen
  runs. `:processes` and `:total` are reported and gated on nothing: their
  run-to-run spread on this workload is about 7,600 bytes per call, so any
  threshold stable enough not to flake would be far too coarse to catch a real
  leak. A gate that has to sit above its own noise floor is not a gate.
  `PTC_GATEWAY_SOAK_CYCLES` sets the batch size.
- **Write durability.** Every call that returned 200 has a matching record on
  disk, with unique call IDs. Read back from the audit files rather than from
  the owner: a record the owner believes it wrote and a record that survives the
  process are different claims, and only the second is what an audit is for.

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

A write deployment cannot put its audit directory under the system temporary
directory on macOS: the private audit refuses a symbolic link anywhere in the
hierarchy and `$TMPDIR` reaches the user's folder through `/var`, which is one
(#1985). The benchmark uses a project-local scratch directory; the gate uses
ExUnit's `:tmp_dir`, which is already project-local.

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

## Private-audit group commit comparison

The original implementation synced each record separately while retaining run
admission. On the original ten-scheduler darwin/arm64 measurement, goodput fell
from 931 to 727 calls/s between concurrency 8 and 64, with 78% refusals and an
audit mailbox mean of 54 at the final level (#1987).

Issue #2025 replaces that serialization with bounded group commit. The same
`mix run bench/gateway_load.exs` sweep before and after the change on this
four-scheduler Linux host, 200 calls per level and unchanged admission limits,
produced the following write results. Latency is client-observed p50/p95/p99 in
milliseconds for accepted calls; mailbox depth is peak/mean. HTTP publication
can precede audit completion, so client latency does not measure the full time
run admission remains held.

| Concurrency | Before goodput/s | After goodput/s | Before refused | After refused | Before latency | After latency | Before audit mailbox | After audit mailbox |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 119 | 119 | 6.5% | 0% | 6.86/12.21/13.09 | 7.59/11.45/13.74 | 63/34.75 | 1/0.02 |
| 2 | 83 | 279 | 90% | 0% | 7.27/11.74/12.67 | 5.75/10.06/10.99 | 63/62.40 | 2/0.07 |
| 4 | 80 | 600 | 96% | 0% | 7.07/9.82/9.82 | 5.36/8.23/10.41 | 63/62.37 | 2/0.17 |
| 8 | 81 | 696 | 95.5% | 0% | 9.28/10.46/10.46 | 10.06/13.33/17.24 | 63/62.38 | 7/0.60 |
| 16 | 99 | 605 | 96% | 0% | 13.14/18.16/18.16 | 22.25/38.53/43.78 | 63/62.07 | 3/0.42 |
| 32 | 96 | 582 | 97% | 0% | 17.12/22.97/22.97 | 46.75/69.95/76.13 | 63/61.75 | 8/0.65 |
| 64 | 84 | 521 | 96.5% | 0% | 30.21/35.19/35.19 | 106.53/136.25/141.06 | 62/61.50 | 32/2.50 |

The baseline reached the 64-run admission ceiling even at low client
concurrency because published calls retained admission while queued for audit.
Batching eliminated refusals in this sweep. High-concurrency latency increased
because those calls now execute rather than being refused; the baseline's few
accepted calls are not an equivalent latency population. Both runs finished
with zero request leases and the same process count before and after the leak
probe. These are observations on one host, not a portable performance gate.

The mailbox sampler excludes records already collected into the current
batch. The audit tests separately enforce the record/byte bounds, light-traffic
flush, ordered batches, shutdown flush, and the sync barrier under success and
failure. The HTTP integration checks that admission stays held at that barrier.
The chosen bounds and durability contract belong to the
[gateway reference](../reference/gateway.md#private-audit-directory).

Read offered load carefully: it counts cheap refusals. Only goodput reports
successful work. An isolated append now includes the batching delay and cannot
predict the throughput of concurrent calls sharing a sync.

## Other operational properties

A request holds one of `max_inflight_requests` from before its body is read
until the response completes, so how long the transport waits for body bytes is
how long one stalled client can hold a slot. That was 15 seconds — the default —
and the raised timeout reached the client as `500 Internal Server Error` with
`-32603`. It is now a two-second budget answered with HTTP 408
`{"error":"request_timeout"}`. `max_inflight_requests` stalled clients still
starve the endpoint for that budget, and `/health/ready` still stays 200
throughout, because readiness reports on the warm runtime rather than on request
admission. A peer that keeps dribbling bytes renews the budget by definition;
the loopback binding and the bearer requirement are what bound that residue.

Connection reuse is worth roughly four times the throughput of one connection
per call at the same concurrency, so a client that opens a socket per tool call
is paying more for TCP than for the workflow.

The gateway itself is not the expensive part. A trivial `tools/call` spends
0.79 ms on connection, parsing, authentication, admission and reservation, and
4.36 ms on activation, the run and publication — and the same call made
in-process through `ServingTemplate.call/3`, with no HTTP at all, costs 3.79 ms.
`tools/list`, which is the whole request path minus the run, completes in
0.47 ms and sustains ~6,700 per second.

## Transport coverage

`GatewayLoad.pipelined/3` writes all requests before reading any reply. The
soak gate checks consecutive JSON-RPC IDs in wire order for both `tools/list`
(content-length framing) and `tools/call` (chunked SSE), with one in-flight
slot and one run slot. Every reply must succeed and both capacities must return
to zero. Reads consume exactly one response, retaining any coalesced bytes for
the next reply.

The socket probe starts Bandit directly over the live router state with two
acceptors and four connections per acceptor. The effective ceiling is eight;
`num_connections` is per acceptor, so the dependency defaults of 100 and 16,384
mean 1,638,400 connections, not 16,384. The probe opens twelve idle keep-alive
sockets, reports queued versus refused exchanges and health reachability on a
new socket, and checks recovery after closing them. Request leases and run
capacity must stay zero while only idle sockets consume the transport. It does
not change `Domain.listen/2`; listener policy is decided separately from these probe limits.

Measured on Linux with the dependency defaults for retry timing: all twelve
TCP handshakes succeeded; eight `/health` exchanges returned HTTP 404, and four
had no response during a 100 ms read per socket. A thirteenth socket also
connected but its health request timed out. Both application counters stayed
zero. Closing the twelve sockets let the pending health request return within
the five-second recovery budget, followed by successful readiness and MCP calls.
This is transport queuing, not application admission refusal. Some excess
sockets are accepted by an acceptor waiting to create a handler, while the rest
wait in the listen backlog; the wire observation does not distinguish those
locations. The observation ends before the dependency's five one-second
retries can exhaust, so it does not claim excess sockets remain queued forever.

For measurements with a separate client process, see
[the optional oha benchmark](https://github.com/andreasronge/ptc_runner/blob/main/ptc_gateway/bench/README.md). The existing
in-process client's scheduler competition inflates latency and reduces
throughput, so its absolute figures should not be read as server capacity.

The raw-socket clients connect to the numeric loopback tuple directly. Resolving
its textual address lazily starts two persistent resolver processes on the
first call, which otherwise makes the exact process-count gate depend on test
order. Those processes belong to the client, not to the gateway.
