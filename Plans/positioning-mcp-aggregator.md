# Positioning: PtcRunner-MCP-Aggregator vs MCP Orchestration Landscape

## Purpose

This document captures defensible positioning for PtcRunner-MCP-Aggregator
(`Plans/ptc-runner-mcp-aggregator.md`) against the existing MCP
orchestration landscape, and tracks **feature signals** that fall out of
peer comparison — items the aggregator might want to add as the
"Code Mode" peer group matures. It is a reference for future README
sections, docs, blog posts, talks, and PR descriptions, and a feeder for
roadmap discussions.

It is **not** an implementation plan. Claims here are pitched at a level
that reasonable readers can verify against the cited sources or against
a working aggregator. Roadmap items in §"Feature signals" are
candidates, not commitments.

**Revision note (2026-05):** the original doc compared only against
agent frameworks (mcp-agent, LangGraph, OpenAI Agents SDK). The closer
peer category turned out to be **"Code Mode" MCP servers** — Cloudflare
Code Mode, MCPProxy's `code_execution`, mcpfy, and the pattern in
Anthropic's "Code execution with MCP" engineering post. Those peers
match the aggregator's shape ("one MCP server, sandbox executes LLM-
written code, code calls upstream MCP tools") and shrink the defensible
differentiator set. This revision adds them, retires claims they
neutralize, and seeds a feature-signal section.

## What it is (one line)

PtcRunner-MCP-Aggregator is a **sandboxed code-as-tools primitive where
the code is LLM-written PTC-Lisp and the tools are upstream MCP servers.**
It is not an agent framework. It is a deterministic execution layer that
an agent framework, or an MCP client directly, can call.

## The orchestration landscape

The MCP ecosystem has converged on a recognized problem: raw tool exposure
does not scale. Hundreds of tools per client produces token bloat,
degraded tool selection, hallucinated calls, and large outputs flooding
context. The community response is a layer between the LLM and the raw
MCP servers.

The major shapes today:

| System | Who writes orchestration | Internal LLM calls during a workflow? | Layer |
|---|---|---|---|
| [mcp-agent](https://docs.mcp-agent.com/mcp-agent-sdk/mcp/overview) | App developer (agents call MCP tools directly, or AugmentedLLM invokes them during generation) | Yes — agent loops involve model calls | Agent framework |
| [OpenAI Agents SDK + MCP](https://openai.github.io/openai-agents-python/mcp/) | App developer (Python; supports tool filtering, tracing, cached `tools/list`, `MCPServerManager` for multiple servers) | Yes — the agent runs LLM loops | Agent framework |
| [LangChain / LangGraph + MCP](https://docs.langchain.com/oss/python/langchain/mcp) | App developer (graph nodes; uses MCP adapters to expose tools from one or more servers) | Yes — nodes typically call LLMs | Workflow framework |
| Custom Python orchestrators | App developer (hand-coded) | Usually no | Pre-written workflow |
| Progressive tool discovery (`search_tools` / `inspect_tool` / `execute_tool`) | n/a — selection pattern | n/a | Selection layer |
| Tool routers / gateways (semantic retrieval) | n/a — selection pattern | n/a | Selection layer |
| **PtcRunner-MCP-Aggregator** | **The caller's LLM, on the fly, in PTC-Lisp** | **No** — execution performs upstream MCP calls as code, with no planner/model in the loop | **Programmatic tool-calling primitive** |

None of the **agent-framework** systems above is primarily "one MCP
server that exposes a sandboxed language to call upstream MCP tools."
The layer distinction is real for that group. A different peer category
— Code Mode MCP servers — *does* match that shape and is covered next.

## The closer peers: Code Mode MCP servers

The Code Mode pattern (after Cloudflare's October 2025 post) is the
direct peer group: a single MCP server advertises a code-execution tool;
the LLM writes a small program; the program calls upstream MCP tools via
a sandbox-internal primitive; intermediate JSON never enters the LLM's
context.

| System | Sandbox language | Sandbox runtime | Upstream-call primitive | Catalog discovery | Schema-validated return | Hosting |
|---|---|---|---|---|---|---|
| [Cloudflare Code Mode](https://blog.cloudflare.com/code-mode/) | TypeScript | V8 isolates (Workers) | Typed RPC bindings generated from upstream MCP schemas | Inline typed API with doc comments | None standard | Practical only on Cloudflare Workers |
| [MCPProxy `code_execution`](https://github.com/orgs/modelcontextprotocol/discussions/627) | JavaScript (ES5.1+) | Restricted JS VM, no Node modules | `call_tool(serverName, toolName, args)` | Server allowlist + system-prompt | None | Self-host |
| [Anthropic "Code execution with MCP"](https://www.anthropic.com/engineering/code-execution-with-mcp) | Pattern (TS examples) | Operator's choice | Tool defs as files in a sandboxed FS | Filesystem-of-tool-defs, lazy reads | None standard | Pattern, not a packaged server |
| [mcpfy](https://mcpfy.ai/blog/mcp-code-execution-launch/) | JS/TS | Hosted sandbox | Hosted upstreams | Hosted catalog | None | Hosted SaaS |
| `hermes-agent` (NousResearch) | Python | Restricted runtime | Inside an agent loop | Internal | None | Agent framework, not a standalone MCP server |
| **`ptc_runner_mcp` aggregator** | PTC-Lisp (Clojure subset) | BEAM process — no I/O *by construction* | `(tool/mcp-call {:server … :tool … :args …})` | Inline catalog in `tools/list` description | First-class `signature` + structured `upstream_calls` audit | Self-host single Mix release |

This is the comparison the project should be measured against. Several
of the original "defensible differentiators" below are shared with this
group rather than unique to PtcRunner; the next section splits them
explicitly.

## Defensible differentiators

The differentiators below now split into two groups: claims that hold
against **agent frameworks** (mcp-agent, LangGraph, OpenAI Agents SDK)
and the narrower set that holds against **Code Mode peers**.

### Against agent frameworks

**1. One LLM turn writes the program; execution has no internal LLM calls.**

The caller's LLM still spends tokens writing the PTC-Lisp program and
reading the final result. The defensible claim is narrower: execution
does not run a planner LLM between tool calls. mcp-agent's planner agent,
LangGraph nodes that invoke models, and the OpenAI Agents SDK's agent
loops all add internal LLM round-trips during a workflow. The aggregator
adds none. *(Shared with all Code Mode peers — not a differentiator
inside that group.)*

**2. Deterministic composition over nondeterministic external tools.**

The PTC-Lisp program is deterministic given inputs. Upstream MCP tools
themselves may hit live APIs, stateful browser sessions, rate limits, or
auth scopes — that part is nondeterministic. Given the same upstream
tool outputs, the program runs identically every time. No LLM-judgment
variance in the orchestration step. *(Shared with all Code Mode peers.)*

**3. Cross-language MCP-native.**

mcp-agent, OpenAI Agents SDK, and LangGraph are Python ecosystems —
adoption requires writing Python and running a Python process. The
aggregator is invokable from any MCP client: Claude Desktop, Cursor,
Cline, Claude Code, plus custom MCP clients in any language. *(Shared
with the other Code Mode MCP servers; specifically not shared with the
"pattern" implementations or with `hermes-agent`.)*

**4. LLM-written, not developer-written, orchestration.**

Custom Python orchestrators hand-code workflows like `research_company()`.
mcp-agent's multi-agent definitions are written by the developer.
LangGraph's graph nodes are too. The aggregator inverts this: zero
deployment overhead, the LLM composes a one-off PTC-Lisp program per
task. *(Shared with all Code Mode peers.)*

### Against Code Mode peers

The Code Mode pattern shares the core idea. What separates PtcRunner
aggregator inside that category:

**A. Signature-validated returns.**

`signature` is a first-class field on `lisp_eval`. The runtime
validates the program's return value against the schema, coerces where
unambiguous, and surfaces a structured `validation_error` on mismatch
that the LLM can self-correct from. Cloudflare Code Mode, MCPProxy,
mcpfy, and the Anthropic pattern all return raw JS values or
`console.log` output without schema validation. This is genuinely unique
in the peer set and matters for programmatic clients consuming results.

**B. Structured `upstream_calls` audit trail.**

Every `tool/mcp-call` is recorded on the response with server, tool,
args (truncated), outcome, and reason. JS Code Mode peers surface call
metadata only via logs or exceptions, with no standardized shape.
Useful for trust, debugging, billing attribution, and policy auditing.

**C. Three-class failure model.**

`tool/mcp-call` returns *value | nil | runtime-error envelope*, where
`nil` means world-fault (timeout, oversize response, cap exhausted —
reason recorded in `upstream_calls`) and the envelope means
programmer-fault (unknown server / tool / unencodable args). Programs
write `(remove nil? results)` to discard transient failures while still
crashing on programming errors. JS Code Mode peers collapse both into
exceptions, putting the burden of distinguishing them on the LLM. This
is structurally different and arguably better for LLM self-correction.

**D. `pmap` as a first-class form.**

`(pmap #(tool/mcp-call …) xs)` is one short expression and the language
encourages it. JS Code Mode peers need `Promise.all(xs.map(…))` — same
outcome, more code, easier to forget. The README's ~3× wall-clock
speedup claim for parallel cross-server workflows leans on this
ergonomic pull.

**E. "Language without I/O" sandbox vs. JS-with-restrictions.**

Cloudflare's V8 isolates and MCPProxy's restricted JS VM are
general-purpose interpreters with the dangerous APIs removed. PTC-Lisp
has no `eval`, no FFI, no network primitives, no file primitives — the
language doesn't *contain* the dangerous operations to remove. Smaller
attack surface, simpler static analysis, no isolate-escape CVE class.
Different threat model, not strictly "better"; Cloudflare's V8 is far
more battle-tested than PTC-Lisp.

**F. Self-hostable single binary, no cloud dependency.**

Cloudflare Code Mode is practical only on Workers. mcpfy is hosted SaaS.
PtcRunner ships as a single Mix release with BEAM bundled and works
fully offline behind a corporate firewall. MCPProxy shares this property
but is prototype-grade. For air-gapped or vendor-averse deployment, the
field shrinks to PtcRunner and MCPProxy.

## Plausible (but not yet proven) claim

**PTC-Lisp has a smaller surface than Python, which should make generated
orchestration easier to constrain, test, and sandbox.**

This is plausible but not proven. We don't have eval data comparing
LLM-generated PTC-Lisp success rates against LLM-generated Python on the
same tasks. The argument is structural: smaller surface = fewer ways to
go wrong + simpler static analysis + easier sandboxing.

Treat as a hypothesis to validate, not a hard differentiator. Once we
have benchmark data (R32-style, see the sibling plans), this can be
upgraded or revised.

## Honest weaknesses

**1. Workflows requiring model judgment between tool calls.**

If a workflow genuinely needs the LLM to think between tool calls — "look
at these search results, decide which one to dig into based on judgment"
— it cannot be expressed in a single PTC-Lisp program. The LLM has to
make multiple round-trips to `lisp_eval`. mcp-agent's multi-agent
workflows handle this natively in one orchestration session.

If your workflow is "tool, think, tool, think, tool," the aggregator
forces multi-turn. If it's "tool, tool, tool, compose, return," the
aggregator does it in one turn.

**2. Reliability for repeated production workflows.**

A hand-written `research_company()` in Python beats an LLM-generated
PTC-Lisp program every time for the 1000th run of a known workflow. The
aggregator excels at ad-hoc exploration and one-off composition. Mature
production workflows benefit from deterministic hand-coded orchestrators.
These are different jobs.

**3. Ecosystem maturity.**

mcp-agent, LangGraph, and Cloudflare Code Mode all have production
usage and observability tools. Cloudflare specifically has Workers-grade
tail/logs/metrics out of the box — PtcRunner's `--trace-dir` JSONL is
solid for self-host but not in the same league. The aggregator is
greenfield; the first six months will surface edge cases the mature
systems already handled.

**4. Tool catalog token cost.**

Embedding the upstream catalog inline in the `lisp_eval`
description costs tokens on every request. Anthropic's filesystem-of-
tool-defs pattern (lazy, on-demand reads) and Cloudflare's typed-API
generation handle this better at scale (200+ tools). The aggregator
works fine for typical configs (3–10 servers, 30–50 tools); larger
setups would benefit from a router upstream of it, or from adopting one
of the discovery patterns described in §"Feature signals."

**5. Language familiarity.**

Developers know TypeScript and Python. Few know Clojure-ish PTC-Lisp.
Cloudflare Code Mode and MCPProxy generate TS/JS, which most reviewers
can read. If a generated PTC-Lisp program needs human review or
debugging, there is a learning curve. (Matters less for end-users —
they don't read the code, just see the result.)

**6. ~~Stdio-only upstreams in v1.~~** ✅ **RETIRED** (delivered by
`Plans/http-transport-credentials.md`).

The aggregator now supports HTTP-transport upstreams (Streamable HTTP,
MCP rev 2025-06-18) alongside stdio. Operators can wrap remote MCPs
that have no stdio surface — GitHub MCP at
`https://api.githubcopilot.com/mcp/`, Cloudflare-hosted MCPs,
organization-internal HTTP MCPs behind SSO gateways. v1 does not
implement OAuth flows, mTLS, or persistent token storage; static-secret
bindings (env / file / literal) cover the common case. SSE GET
subscriptions for server-pushed notifications are deferred to v1.x —
a cached `tools/list` is refreshed on Connection restart, same as
stdio.

**7. ~~Credential-binding model is weaker than Cloudflare's.~~** ✅
**RETIRED-WITH-CAVEAT** (delivered by `Plans/http-transport-credentials.md`;
threat-model parity for the leak vector, NOT for the sandbox-isolation
threat model).

The aggregator now ships a credentials registry (`PtcRunnerMcp.Credentials`)
with three properties that close the leak vector this section originally
flagged:

1. **Structural isolation.** Resolved auth bytes are not stored in
   upstream config maps, Connection state, trace JSONL,
   `upstream_calls` envelopes, or Logger output. They live only in
   the Credentials GenServer state, the redaction-set ETS table,
   transient HTTP-header construction variables, and the in-flight
   Req request — by construction, not by convention.
2. **Binding indirection.** `auth:` references named bindings; the
   value is resolved at request time and never appears in
   `inspect/2` of any state. The opaque `%RedactedHeaders{}` wrapper
   renders `[REDACTED]` even when transitively contained.
3. **Defense-in-depth redaction.** A redactor substring-replaces
   registered plaintext with `[REDACTED]` in every formatted string
   the Log / TraceFile / TracePayload / UpstreamCalls / TraceHandler
   writers emit, in case any code path bypasses the structural rules.

This gives **functional parity** with Cloudflare Code Mode for the
specific threat: "a misbehaving upstream that echoes its env (or, on
HTTP, its request headers) back through a tool result." A 16-cycle
randomized-secret property test (`test/ptc_runner_mcp/redaction_end_to_end_test.exs`)
asserts the secret never appears in trace JSONL, log capture, or
GenServer state across handshake-and-call cycles.

**The remaining gap is sandbox isolation, not the leak vector.**
Cloudflare's V8-isolated bindings are a different threat model: the
sandboxed code literally cannot hold the secret bytes (no JS reference
to them exists), so even a sandbox escape cannot exfiltrate. PtcRunner
resolves bindings into the BEAM runtime's process memory; a sandbox
escape that reached arbitrary Erlang term inspection could in
principle find the bytes. PTC-Lisp's sandbox model is process-isolation
+ allow-list of safe functions, not V8-isolate-grade bytecode
verification — so this threat-model gap stays open.

Operators who need V8-isolate-grade secret hiding pick Cloudflare
Code Mode. Operators who need self-host + structural isolation +
in-process redaction pick PtcRunner. Both points on the trade-off
curve are legitimate; the leak vector this section once flagged is
no longer one of them.

## Composition story (works with, not against)

The aggregator does not replace mcp-agent, LangGraph, or the OpenAI
Agents SDK. It composes with them at a different layer.

Concrete patterns:

- **Aggregator inside an agent framework.** A sub-agent in
  mcp-agent or LangGraph could call the aggregator's `lisp_eval`
  for deterministic compute over results, instead of trying to do joins
  or aggregates in LLM context. The framework provides multi-agent
  reasoning; the aggregator provides deterministic compute.
- **Aggregator + progressive tool discovery.** Complementary. Progressive
  discovery solves "which schemas does the LLM see?" The aggregator
  solves "how does the LLM compose tools efficiently?" A future version
  of the aggregator could lazy-load upstream schemas — that *is*
  progressive discovery applied inside aggregator mode.
- **Aggregator behind a semantic router.** A router decides "this query
  needs cross-server compose," routes to the aggregator; another query
  needing single-tool lookup goes direct.

The position is layer, not competition. mcp-agent and LangGraph are
**orchestration frameworks for developers writing apps**. The aggregator
is **a programmatic tool-calling primitive an app, framework, or MCP
client can call**.

The right analogy: PtcRunner-aggregator is to MCP what NumPy is to data
science — a fast, deterministic, focused primitive that higher-level
frameworks build on, and end-users can use directly when their problem
is small enough.

## When to pick what

Three questions a deployer should ask, in order:

**1. Do I want orchestration logic written by an LLM on the fly, or by
a developer once?**

- LLM, on the fly → any Code Mode peer (PtcRunner aggregator, Cloudflare
  Code Mode, MCPProxy, mcpfy).
- Developer, once → mcp-agent / LangGraph / custom Python orchestrator.

**2. Do I want zero internal LLM calls during execution, or am I OK
paying for a planner agent?**

- Zero internal calls → any Code Mode peer.
- OK with planner reasoning → mcp-agent / Agents SDK / LangGraph.

**3. Inside the Code Mode group, what tradeoffs do I want?**

- **Cloudflare Code Mode** — best ecosystem, typed TS bindings, hidden
  credentials, but cloud-only and no schema-validated returns.
- **MCPProxy** — self-hostable JS sandbox, simple `call_tool` primitive,
  prototype-grade.
- **PtcRunner aggregator** — typed return signatures, structured audit
  trail, three-class failure model, BEAM "language without I/O" sandbox,
  self-hostable single binary, stdio + Streamable HTTP upstreams,
  bindings-based credentials with structural redaction. PTC-Lisp
  learning curve still applies.
- **mcpfy** — hosted SaaS take.
- **Anthropic pattern** — DIY; pick this if you want full control and
  are willing to build it.

For ad-hoc, exploratory, end-user-facing scenarios with self-host /
offline constraints, those tradeoffs lean toward PtcRunner. For
production workflows with known structure, they lean toward the
existing frameworks. For teams already on Cloudflare Workers, Code Mode
is the path of least resistance. Code Mode peers and agent frameworks
compose at different layers.

## Sequencing note

The four-plan family in `Plans/`:

- `ptc-lisp-tool-call-transport.md` (shipped foundation)
- `ptc-runner-mcp-server.md` (MCP v1, no upstream tools)
- `text-mode-ptc-compute-tool.md` (in-process `:text` + `:tool_call`)
- `ptc-runner-mcp-aggregator.md` (MCP server with upstream wrapping)

**Sequencing recommendation: text-mode first is product sequencing, not a
hard technical dependency.**

Technically, the aggregator can follow MCP v1 without waiting for
text-mode. The `PtcToolProtocol` Phase 0 extraction is the only shared
prerequisite.

Product-wise, text-mode first is cleaner because it settles shared
concepts in a smaller surface: exposure policy, preview/cache language,
"PTC as deterministic-compute affordance." The aggregator then becomes
the out-of-process version of the same story, and the messaging is
already in place.

Either order works; pick based on which user demand is louder.

## Feature signals from peer comparison

These are roadmap candidates that fall directly out of comparing
PtcRunner aggregator against the Code Mode peer set. They are *not*
commitments — each one needs its own scoping doc, design discussion,
and prioritization. They are listed roughly in order of expected impact.

### High-impact

**1. Typed catalog generation (Cloudflare-style).**

Today the aggregator inlines a free-form catalog into the
`lisp_eval` tool description. Cloudflare generates a typed TS
API from upstream MCP schemas and gives the LLM autocomplete-shaped
guidance. PtcRunner equivalent: convert each upstream tool's JSON Schema
into a PTC-Lisp signature spec inlined into the catalog, so the LLM
sees `:server "github" :tool "get_pr" :args {:number :int}` shapes
natively. Likely improves first-try program correctness; should be
benchmarkable against the current free-form catalog.

**2. Lazy / filesystem-style catalog discovery (Anthropic pattern).**

Inline catalogs blow up past ~50 tools. Expose upstream catalogs as a
PTC-Lisp-callable directory of definitions — e.g. `(catalog/list-servers)`,
`(catalog/list-tools "github")`, `(catalog/describe-tool "github"
"get_pr")` — so the LLM reads schemas on demand instead of paying the
catalog tax on every request. Required for credible large-fleet (200+
tool) deployments.

**3. ~~HTTP / SSE / Streamable HTTP upstream transport.~~** ✅
**DELIVERED** by `Plans/http-transport-credentials.md` (commits
`76f68de..78096cb`). PtcRunner now wraps Streamable HTTP upstreams
(MCP rev 2025-06-18) alongside stdio. Validated against the live
GitHub MCP server (`https://api.githubcopilot.com/mcp/`) via the
opt-in `@real_remote_upstream` test in
`mcp_server/test/ptc_runner_mcp/upstream/http_real_github_test.exs`.
Long-lived SSE GET subscriptions for server-pushed notifications are
deferred to v1.x — `tools/list` refresh on Connection restart matches
the stdio semantics.

**4. ~~Credential-binding model (Cloudflare-style).~~** ✅ **DELIVERED**
by `Plans/http-transport-credentials.md` (commits
`43640bd..a73b930`). Top-level `credentials:` config block holds named
bindings (env / file / literal sources; `exec` deferred to v1.1).
HTTP `auth:` emitter list references bindings by name; the program
references `:server "github"` and the runtime resolves + applies
auth headers out-of-band. Structural isolation closes the
"misbehaving upstream echoes env back" leak vector — see Honest
Weakness #7 (retired-with-caveat) for the full parity statement.

### Medium-impact

**5. OTel / structured trace export.**

`--trace-dir` writes JSONL files. Exporting OpenTelemetry spans for the
program lifecycle and each `tool/mcp-call` would slot into existing
observability stacks and close some of the maturity gap with Cloudflare
Workers' native tooling.

**6. Per-upstream allowlist / quarantine.**

MCPProxy has a quarantine system — programs can be restricted to a
subset of configured upstreams per call, not just per-server-config.
Useful for least-privilege multi-tenant deployments where a single
aggregator process serves multiple trust domains.

**7. Streaming results back to the client.**

`lisp_eval` is request/response. Long-running aggregator programs
(scraping, large fan-out) would benefit from streaming partial results
or progress events. Cloudflare Workers' streaming response semantics
are the obvious reference.

### Lower-impact / speculative

**8. Cached `tools/list` for upstreams.**

OpenAI Agents SDK caches upstream tool listings. PtcRunner currently
re-asks each upstream on its `tools/list` invalidation cycle. Caching
plus invalidation hooks is straightforward and might shave catalog-load
latency.

**9. Eval suite comparing PTC-Lisp to TS Code Mode generation success.**

Currently the "smaller surface than Python/TS → easier to generate
correctly" claim is structural, not measured. A R32-style benchmark
across the same workflows generated as PTC-Lisp vs. as Cloudflare-style
TS would either upgrade this from "plausible" to "demonstrated" or
revise it. Worth running before making the structural claim louder
externally.

**10. Multi-turn aggregator programs with model judgment.**

The biggest "honest weakness" is workflows needing the model to think
between calls. A future mode could let `lisp_eval` be invoked
multi-turn within one session — preserving program state across calls,
letting the model inject judgment between phases. Risks blurring the
"deterministic primitive" identity; needs careful scoping.

### Explicit non-goals

For clarity on what *not* to chase:

- **Becoming an agent framework.** mcp-agent / LangGraph already do
  this. PtcRunner aggregator's identity is the deterministic primitive.
- **Becoming a gateway.** MetaMCP / Microsoft mcp-gateway / Kong already
  do this. PtcRunner aggregator does *not* advertise upstream tools as
  flat siblings — it advertises one tool that calls upstreams.
- **Hosted SaaS.** mcpfy and Cloudflare Code Mode cover that segment.
  PtcRunner's value is self-host / single-binary / offline.

## Bottom-line claims (defensible, for docs)

1. PtcRunner-MCP-Aggregator is a **programmatic tool-calling primitive**
   in the **Code Mode** category, not an agent framework or a gateway.
2. It **composes with** mcp-agent / LangGraph / OpenAI Agents SDK rather
   than replacing them, and is one of several Code Mode peers (Cloudflare
   Code Mode, MCPProxy, mcpfy, Anthropic pattern) rather than a unique
   instance of the pattern.
3. Its differentiators inside the Code Mode group are **schema-validated
   returns**, a **structured `upstream_calls` audit trail**, a
   **three-class failure model**, **`pmap` ergonomics**, a **BEAM
   "language without I/O" sandbox**, and **self-hostable single-binary
   deployment with no cloud dependency**.
4. Its honest weaknesses are **workflows that require model judgment
   between tool calls**, **catalog token cost at scale**,
   **PTC-Lisp learning curve for human reviewers**, and the
   **sandbox-isolation gap vs. Cloudflare's V8 isolates** (binding
   credentials are structurally redacted but live in BEAM process
   memory; a sandbox escape that reached arbitrary term inspection
   could in principle find them — this is a different threat model
   than V8-isolate-grade hiding).

Anything stronger than these four claims needs supporting data before it
goes into a README or talk.

## Citations

Primary documentation for the systems compared in this brief:

**Agent frameworks:**
- mcp-agent: https://docs.mcp-agent.com/mcp-agent-sdk/mcp/overview
- OpenAI Agents SDK + MCP: https://openai.github.io/openai-agents-python/mcp/
- LangChain / LangGraph + MCP: https://docs.langchain.com/oss/python/langchain/mcp

**Code Mode peers (closer peer group):**
- Cloudflare Code Mode: https://blog.cloudflare.com/code-mode/
- Anthropic "Code execution with MCP": https://www.anthropic.com/engineering/code-execution-with-mcp
- MCPProxy `code_execution` discussion: https://github.com/orgs/modelcontextprotocol/discussions/627
- OpenSandbox + Code Mode walkthrough: https://dev.to/thangchung/mcp-programmatic-tool-calling-code-mode-with-opensandbox-4n3n
- mcpfy MCP Code Execution: https://mcpfy.ai/blog/mcp-code-execution-launch/

**Aggregator / gateway landscape (out of scope for this doc but useful for cross-reference):**
- MCP Aggregation, Gateway, and Proxy ecosystem survey (Q1 2026):
  https://www.heyitworks.tech/blog/mcp-aggregation-gateway-proxy-tools-q1-2026
- Awesome MCP gateways (curated list): https://github.com/e2b-dev/awesome-mcp-gateways

If the comparison tables or claims drift from these sources as those
projects evolve, update this document — do not let drift accumulate
silently into PtcRunner's positioning materials.
