# Positioning: PtcRunner-MCP-Aggregator vs MCP Orchestration Landscape

## Purpose

This document captures defensible positioning for the future
PtcRunner-MCP-Aggregator (`Plans/ptc-runner-mcp-aggregator.md`) against
the existing MCP orchestration landscape. It is a reference for future
README sections, docs, blog posts, talks, and PR descriptions when the
feature ships.

It is **not** a plan. It does not specify implementation. Claims here are
pitched at a level that reasonable readers can verify against the cited
sources or against a working aggregator.

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

None of the systems above are primarily "one MCP server that exposes a
sandboxed language to call upstream MCP tools." The layer distinction is
real.

## Defensible differentiators

**1. One LLM turn writes the program; execution has no internal LLM calls.**

The caller's LLM still spends tokens writing the PTC-Lisp program and
reading the final result. The defensible claim is narrower: execution
does not run a planner LLM between tool calls. mcp-agent's planner agent,
LangGraph nodes that invoke models, and the OpenAI Agents SDK's agent
loops all add internal LLM round-trips during a workflow. The aggregator
adds none.

**2. Deterministic composition over nondeterministic external tools.**

The PTC-Lisp program is deterministic given inputs. Upstream MCP tools
themselves may hit live APIs, stateful browser sessions, rate limits, or
auth scopes — that part is nondeterministic. The accurate claim is
"deterministic composition over nondeterministic external tools," not
"fully deterministic workflow."

What this buys you: given the same upstream tool outputs, the program
runs identically every time. No LLM-judgment variance in the
orchestration step.

**3. Sandboxing as a structural property.**

Aggregator mode does not give generated code arbitrary filesystem,
network, or process access. External effects happen only through
configured upstream MCP tools and runtime-enforced budgets (timeouts,
memory limits, max upstream calls per program, max upstream response
bytes). That is a meaningfully smaller blast radius than running
LLM-generated Python or letting agents shell out.

This matters for daemon-shaped multi-tenant deployment and for
safety-conscious users who don't want to give an LLM-controlled agent
unlimited compute.

**4. Cross-language MCP-native.**

mcp-agent, OpenAI Agents SDK, and LangGraph are Python ecosystems —
adoption requires writing Python and running a Python process. The
aggregator is invokable from any MCP client: Claude Desktop, Cursor,
Cline, Claude Code, plus custom MCP clients in any language. The MCP
protocol normalizes adoption. None of the Python frameworks have this
property because they *are* the framework, not an MCP server you can drop
into existing setups.

**5. LLM-written, not developer-written, orchestration.**

Custom Python orchestrators hand-code workflows like `research_company()`.
mcp-agent's multi-agent definitions are written by the developer.
LangGraph's graph nodes are too. The LLM picks pre-written workflows from
a menu.

The aggregator inverts this: zero deployment overhead, the LLM composes a
one-off PTC-Lisp program for each new task. No code release for new
workflows. Trade-off captured under "honest weaknesses" below.

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
make multiple round-trips to `ptc_lisp_execute`. mcp-agent's multi-agent
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

mcp-agent and LangGraph have production usage, observability tools,
debugging affordances. The aggregator is greenfield. The first six months
will surface edge cases the mature systems already handled.

**4. Tool catalog token cost.**

Embedding the upstream catalog inline in the `ptc_lisp_execute`
description costs tokens on every request. Progressive discovery and
semantic retrieval handle this better at scale (200+ tools). The
aggregator works fine for typical configs (3–10 servers, 30–50 tools);
larger setups would benefit from a router upstream of it.

**5. Language familiarity.**

Developers know Python. Few know Clojure-ish PTC-Lisp. If a generated
program needs human review or debugging, there is a learning curve. (This
matters less for end-users — they don't read the code, just see the
result.)

## Composition story (works with, not against)

The aggregator does not replace mcp-agent, LangGraph, or the OpenAI
Agents SDK. It composes with them at a different layer.

Concrete patterns:

- **Aggregator inside an agent framework.** A sub-agent in
  mcp-agent or LangGraph could call the aggregator's `ptc_lisp_execute`
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

Two questions a deployer should ask:

**1. Do I want orchestration logic written by an LLM on the fly, or by a
developer once?**

- LLM, on the fly → PtcRunner-aggregator.
- Developer, once → mcp-agent / LangGraph / custom Python orchestrator.

**2. Do I want zero internal LLM calls during execution, or am I OK
paying for a planner agent?**

- Zero internal calls → PtcRunner-aggregator.
- OK with planner reasoning → mcp-agent / Agents SDK / LangGraph.

For ad-hoc, exploratory, end-user-facing scenarios, those tradeoffs lean
toward the aggregator. For production workflows with known structure,
they lean toward the existing frameworks. Both are valid, and they
compose.

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

## Bottom-line claims (defensible, for docs)

1. PtcRunner-MCP-Aggregator is a **programmatic tool-calling primitive**,
   not an agent framework.
2. It **composes with** mcp-agent / LangGraph / OpenAI Agents SDK rather
   than replacing them.
3. Its core advantage: **one LLM-authored sandboxed program can call
   many upstream MCP tools while keeping intermediate data out of LLM
   context.**
4. Its honest weakness: **workflows that require model judgment between
   tool calls.**

Anything stronger than these four claims needs supporting data before it
goes into a README or talk.

## Citations

Primary documentation for the systems compared in this brief:

- mcp-agent: https://docs.mcp-agent.com/mcp-agent-sdk/mcp/overview
- OpenAI Agents SDK + MCP: https://openai.github.io/openai-agents-python/mcp/
- LangChain / LangGraph + MCP: https://docs.langchain.com/oss/python/langchain/mcp

If the comparison table or claims drift from these sources as those
projects evolve, update this document — do not let drift accumulate
silently into PtcRunner's positioning materials.
