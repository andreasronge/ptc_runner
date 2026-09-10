# Sustained TLS connection reuse — 2026-09-10

## Decision

Keep configured ReqLLM/Finch for the first inbound MCP gateway. Put aggregate
request admission above it. Do not adopt the current experimental
`ptc_llm_http` transport: it opens a fresh TLS connection for every request.

## Result

Both adapters completed the same two-attempt support-triage workflow for at
least 30 seconds at concurrency two, with no incorrect or failed workflows.

| Adapter | Workflows | Requests | TLS connections | Requests per connection | Workflows/second | p95 workflow latency |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ReqLLM/Finch | 856 | 1,712 | 2 | 856 | 28.53 | 76.53 ms |
| `ptc_llm_http` pilot | 730 | 1,460 | 1,460 | 1 | 24.31 | 93.30 ms |

ReqLLM passed the fixed reuse envelope. The pilot failed it. The local timing
also favored ReqLLM, but timing is secondary: loopback cannot represent public
DNS, network, TLS, or provider connection-limit costs.

## Provenance and limits

The [machine-readable report](llm-transport-sustained-2026-09-10.json) was
created only after verifying clean checkouts before and after the run. It pins
PtcRunner `3c5e762c51b066198d0181260e349b90f3ca19b7` and `ptc_llm_http`
`cfc88690ac64455c5ddef0ad433f65985572d28c`.

The persistent fixture deliberately covers HTTP/1.1 requests with bounded
`Content-Length` bodies. Existing cancellation and recovery cases remain the
resource-lifecycle evidence. This result decides the current pooling question;
it does not establish public-network latency or complete the MCP gateway.
