# Aggregator Catalog Discovery — Discussion Doc

## Status

**Discussion material, not a specification.** This document captures
research and options analysis for how PtcRunner-MCP-Aggregator should
expose upstream tool catalogs to the calling LLM. It seeds a future
specification once the team picks a direction; it does not commit to
one.

Started: 2026-05-09. Author: collaborative session, see git log.

**Revision (2026-05-09, late):** first draft leaned too hard on the
industry's 405k-token horror stories without sizing PtcRunner's own
curve, undersold the structural advantage of keeping discovery inside
the sandbox, and treated semantic retrieval as deferred rather than
out-of-scope. This revision sizes the actual problem, promotes the
structural advantage to its own section, adds latency-vs-token
tradeoffs that the cited industry numbers gloss over, and sharpens
the family-by-family take.

## Why this matters

The aggregator's current catalog model — inline every upstream tool's
description into the `lisp_eval` tool description at boot,
cached in `:persistent_term`, rebuilt only on PtcRunner restart — is
flagged as a known weakness in
[`Plans/positioning-mcp-aggregator.md`](positioning-mcp-aggregator.md)
§"Honest weaknesses #4" and again as a roadmap candidate in
§"Feature signals from peer comparison" item 2.

### Honest sizing — PtcRunner's own curve

The industry numbers below are real but they describe **clients
exposing 200–400 tools as native MCP tools** (one tool per upstream
operation). That is not PtcRunner aggregator's shape. The aggregator
already collapses N upstreams into one advertised tool; the inline
catalog inside `lisp_eval`'s description is itself a partial
mitigation of the same problem. So the relevant question isn't "are
the cited horror-story numbers scary" — it's "where does *PtcRunner's*
curve put us today and how much headroom is there."

Measured today (sandbox config: 3 upstreams, ~23 tools): roughly
**6 KB / ~1,500 tokens** of inlined catalog. Linear extrapolation
puts a 200-tool fleet at **~30–50 KB / ~7,500–12,500 tokens**. That
is bad and worth fixing — but it is roughly **10–20× headroom** under
even a 200k context window, not "burning down already." Honest
framing: this is preventive work for users we don't have yet, not
crisis triage for users we have today.

> **TODO before this becomes a spec:** measure the actual token cost
> at 50 / 100 / 200 tools with realistic upstream catalogs (GitHub,
> filesystem, memory, slack, etc.) and replace the linear
> extrapolation above with measured points. Linear extrapolation
> understates the cost if upstream descriptions skew long.

### Industry numbers — for reference, not for framing

These are the cited horror stories. They apply to native multi-tool
exposure, **not** to single-tool aggregator architectures. Useful as
ceiling references and for understanding why other projects went
where they did:

- A 400-tool **static** MCP setup consumes **~405,100 tokens**.
  ([Speakeasy](https://www.speakeasy.com/blog/100x-token-reduction-dynamic-toolsets))
- Standard MCP setups consume up to **72%** of an agent's context
  window with tool definitions alone.
  ([Speakeasy v2](https://www.speakeasy.com/blog/how-we-reduced-token-usage-by-100x-dynamic-toolsets-v2))
- The RAG-MCP paper observes "sharp performance degradation once the
  candidate MCP pool exceeds roughly 100 tools."
  ([arXiv 2505.03275](https://arxiv.org/abs/2505.03275))
- Cloudflare's Code Mode reports 2,500+ endpoints in ~1,000 tokens
  versus 1.17M tokens static — 99.9% reduction.
  ([Cloudflare](https://blog.cloudflare.com/code-mode-mcp/))

These set the bar for what's achievable. They do not set our floor.

## The structural insight (this is the actual differentiator)

Every Family 1, 2, and 3 implementation in the field exposes **2–3
meta-tools** to the client. Speakeasy's `list_tools` / `describe_tools`
/ `execute_tool`, Anthropic's filesystem-of-tool-defs, Cloudflare's
`search()` / `execute()`, MCPProxy's `call_tool`. Each of those
becomes:

- a row in client-side traffic,
- an audit-log line,
- a Claude Desktop / Cursor / Cline approval prompt the user has to
  click through (or pre-allowlist),
- a place where catalog discovery latency competes with the user's
  perception of "the assistant is doing work."

PtcRunner aggregator is already a Code Mode server. Discovery can be
expressed as **PTC-Lisp built-ins inside the sandbox** —
`(catalog/list-servers)`, `(catalog/describe-tool …)` — instead of as
new MCP tools. That keeps every property the user-facing surface
already has: **exactly one advertised tool, exactly one approval, no
client-visible discovery traffic, no traffic-shape change**. Discovery
round-trips happen in-process between PTC-Lisp evaluation steps; they
never cross the stdio boundary.

This is not a minor nicety. It is the only way to ship dynamic
discovery without the calling LLM (and the human in front of it)
seeing two or three new "approve `list_tools`?" prompts per task. For
end-user MCP clients with approval gates, that's the difference between
"feature ships" and "feature trains users to click-through." None of
the JS Code Mode peers have this property — they all surface their
discovery primitives as MCP tools by construction.

This is the option Families 1–3 below are evaluated against, and the
reason "do nothing" or "wait and see" is genuinely viable for current
PtcRunner users.

## Solution families in the wild

Five distinct patterns. They are not mutually exclusive.

### Family 1 — Lazy schema loading / progressive discovery

Aggregator advertises 2–3 generic meta-tools instead of N concrete
ones. Schemas surface only when the LLM asks.

Concrete shapes seen:

- **Speakeasy "Dynamic Toolsets"** — `list_tools(prefix)` (names +
  one-liners), `describe_tools(name)` (full schema on demand),
  `execute_tool(name, args)`. 400 tools: 5,500 total tokens vs.
  405,100 static. ~70× reduction.
- **Anthropic "Code execution with MCP"** — same idea, presented as a
  filesystem of tool defs the model `ls`/`read`s lazily. 150,000 →
  2,000 tokens (98.7%) on a specific example.
  ([Anthropic engineering](https://www.anthropic.com/engineering/code-execution-with-mcp))
- **Claude Code lazy MCP loading** — open issue
  [anthropics/claude-code#11364](https://github.com/anthropics/claude-code/issues/11364).
- **Lazy Load MCP server** — packaged version on
  [mcpmarket.com](https://mcpmarket.com/server/lazy-load).

**Tradeoff — token wins ignore latency.** Industry numbers measure
*context*, not *sample efficiency*. Lazy discovery turns one inference
("read inline catalog → write program") into at minimum two serialized
inferences ("call discovery → read result → write program"). For
PtcRunner's current typical config (3–10 servers, 30–50 tools), lazy
is a **wall-clock regression** — same context savings as inline,
double-or-worse latency, no win. Wins only emerge once the inline
catalog actually starts costing meaningful tokens.

The PtcRunner-specific mitigation is keeping discovery inside the
sandbox (see "The structural insight" above): the second inference
disappears because discovery is built-ins inside the program, not new
client-side tool calls. But the program-author LLM still has to know
to call `(catalog/*)` before composing — so even the in-sandbox
version trades token cost against initial-program complexity.

This is why "size-aware default" matters: ship lazy, but keep inline
as the small-config path. See §"Recommendation."

### Family 2 — Semantic retrieval / RAG over tools

Index tool descriptions in a vector store at startup; embed the user's
request; retrieve top-k tools; inject only those.

- **RAG-MCP** (canonical paper). >50% prompt-token reduction; tool-
  selection accuracy 13.6% → 43.1% (3× improvement).
  ([arXiv 2505.03275](https://arxiv.org/abs/2505.03275))
- **Speakeasy `find_tools`** — semantic alternative to their
  progressive shape. 400 tools: 4,300 initial tokens.
- **WRITER engineering** — production deployment writeup.
  ([WRITER](https://writer.com/engineering/rag-mcp/))
- **memoverflow/rag-mcp** — OSS implementation.

**This is the wrong family for PtcRunner aggregator — category
mismatch, not scale mismatch.** The aggregator's value proposition is
**deterministic composition over nondeterministic external tools**
(`Plans/positioning-mcp-aggregator.md` §"Defensible differentiators"
A.2). Embedding-similarity tool selection is fundamentally
nondeterministic: same query, different model rev, different top-k.
Adopting it would put a stochastic step *before* the deterministic
sandbox, undermining the property the aggregator is built to deliver.

This is not "defer until 200+ tools" — it is "out of scope for
PtcRunner aggregator regardless of scale." Operators who need
semantic retrieval at scale should put a router in front of the
aggregator (Family 5), where the nondeterminism is observable as a
separate layer.

### Family 3 — Code Mode with generated typed bindings

Don't lazy-load tools — *generate a typed code API* from the MCP
schemas and let the LLM autocomplete against it. The catalog never
appears as a list; it is encoded into the code-API's type system.

- **Cloudflare Code Mode** with `@cloudflare/codemode`. Schema → TS
  type defs. 2,500+ endpoints in ~1,000 tokens (99.9% reduction).
  ([Cloudflare blog](https://blog.cloudflare.com/code-mode-mcp/),
  [SDK rewrite changelog](https://developers.cloudflare.com/changelog/post/2026-02-20-codemode-sdk-rewrite/))

This pattern fits aggregator architecture more naturally than 1 or 2 —
the aggregator is already a Code Mode server.

**Tradeoff — and one underappreciated PtcRunner-specific upside.**
Schema-to-signature generation is non-trivial: JSON Schema's `oneOf`,
`$ref`, recursive types, and discriminated unions don't all map
cleanly to PTC-Lisp's signature grammar, and PTC-Lisp signatures lack
the autocomplete-shaped richness of TypeScript types in an editor
context.

The upside the original draft missed: **call-time signature
validation**. PTC-Lisp's sandbox can validate `tool/mcp-call` arg
shapes against the generated signature *before* hitting the upstream.
A misuse becomes a structured runtime error pointing at the signature
the LLM should have followed — tighter feedback loop than waiting for
the upstream's own rejection message (which may be a generic 400 or
worse, an opaque MCP error). Combined with PtcRunner's existing
`validation_error` shape, this gives the LLM a clear self-correction
path: "you called tool X with args Y; it requires shape Z." Cloudflare
gets this implicitly via TS compile errors before bytes hit the
sandbox; PtcRunner can do it at runtime, which is roughly equivalent
in feedback quality.

This makes Family 3 more attractive than the schema-translation cost
suggests, but still subordinate to Family 1 in sequencing — typed
bindings need a place to live, and that place is the structured
catalog Family 1 provides.

### Family 4 — Per-call filtering / allowlists

Lightweight, not a real scaling answer. Helps when you *know* which
tools are needed for a route or trust domain.

- OpenAI Agents SDK — `MCPServerManager` with per-call filters,
  cached `tools/list`.
- MetaMCP middleware — drops tools per route.
- MCPProxy — server allowlist + quarantine.

PtcRunner has rough equivalents already (server-level configuration);
nothing tool-level yet.

### Family 5 — Tool routers in front

A semantic router upstream of the aggregator picks which subset of
upstreams to even expose for a given query. Shifts the decision out
of the LLM. Out of scope for the aggregator itself; relevant context.

## How each family maps onto PtcRunner aggregator

See "The structural insight" above for why all viable options stay
inside the sandbox as PTC-Lisp built-ins rather than new MCP tools.

| Family | PTC-Lisp / MCP shape | Cost to ship | Identity impact |
|---|---|---|---|
| Lazy schema loading | `(catalog/list-servers)`, `(catalog/list-tools "github")`, `(catalog/describe-tool "github" "get_pr")` as PTC-Lisp built-ins. `lisp_eval` description shrinks to a one-line "use `(catalog/*)` to discover tools." | Low — pure catalog API design + interpreter built-ins. No new dependencies. | None — still one MCP tool, no new client-visible traffic. |
| Typed bindings (Cloudflare-style) | Generate a PTC-Lisp signature spec per upstream tool from its JSON Schema; inline only signatures. Sandbox validates `tool/mcp-call` args against the signature pre-call. | Medium — JSON Schema → PTC-Lisp signature translation, coverage gaps for complex schemas. | None. Builds on Family 1's structured catalog. |
| Semantic retrieval | n/a — out of scope. Embedding similarity is non-deterministic; conflicts with the aggregator's deterministic-composition identity. | n/a | Identity-incompatible. Operators who need this should use a Family 5 router upstream of the aggregator. |
| Per-call filtering | `:tools` allowlist key in upstreams JSON; runtime check on `tool/mcp-call`. | Low — config plumbing. | None. |
| Tool routers in front | Out of scope for aggregator. | n/a | n/a — different layer. |

### Worked sketch — lazy schema loading inside aggregator mode

This is the highest-leverage option (per the ranking below) and the
one most worth specifying first. Rough authoring shape:

```clojure
;; Discovery
(catalog/list-servers)
;; => ["fs" "github" "mem"]

(catalog/list-tools "github")
;; => [{:name "get_pr" :summary "Fetch a pull request by number."}
;;     {:name "list_issues" :summary "List issues for a repo."}
;;     ...]

(catalog/describe-tool "github" "get_pr")
;; => {:name "get_pr"
;;     :summary "Fetch a pull request by number."
;;     :args-schema {:owner :string :repo :string :number :int}
;;     :returns "MCP envelope: %{:content [...]}"}

;; Then a normal call
(tool/mcp-call {:server "github"
                :tool   "get_pr"
                :args   {:owner "x" :repo "y" :number 42}})
```

What the calling LLM sees in `tools/list` shrinks from "a 50KB inline
catalog of every tool" to roughly:

```
Use (catalog/list-servers), (catalog/list-tools <server>), and
(catalog/describe-tool <server> <tool>) to discover upstream
capabilities on demand. Then call (tool/mcp-call …) with the shape
returned by (catalog/describe-tool …).
```

Plus the existing PTC-Lisp authoring card.

This is a Family 1 implementation; it does not preclude later adding
Family 3 (typed bindings) on top — the `:args-schema` field returned
by `(catalog/describe-tool)` is exactly the place typed bindings would
slot in.

## Recommendation, ordered by impact-to-effort

This is a recommendation for *what to spec first*, not a commitment.

1. **Lazy schema loading via PTC-Lisp built-ins, with size-aware
   fallback to inline (Family 1).** Pure catalog-API design, no new
   dependencies, no embedding service, no schema-translation layer.
   Also the natural prereq for Family 3 — typed bindings need the
   catalog accessible as structured data, which this provides.

   **Critical: ship with size-aware default, not deprecate-and-delete.**
   The inline catalog is genuinely better for small configs (no extra
   inference round-trip, no `(catalog/*)` learning curve for the LLM,
   simpler authoring). Proposed default: render inline if the catalog
   is below a threshold (~30 tools or ~5 KB rendered, both
   measurable at boot); switch to lazy-with-`(catalog/*)`-built-ins
   above. Knob to override either way. The 200-tool case shouldn't
   regress the 10-tool case that's 90% of users today.

2. **Per-call filtering plumbing (Family 4).** Small, complementary,
   useful for multi-tenant deployment. Should land in the same spec
   or shortly after, since the semantics overlap (catalog + visibility).

3. **Typed bindings via signature generation (Family 3).** The
   Cloudflare numbers are the gold standard, and the call-time
   validation feedback loop (above) is a real PtcRunner-specific win.
   Bigger lift — needs a JSON-Schema-to-PTC-Lisp-signature translator
   with sane coverage of complex schema features (`oneOf`, `$ref`,
   recursive types). **Defer until benchmarks justify it** — Family 1
   plus size-aware fallback may be enough for any realistic PtcRunner
   deployment, and the schema-translation work is wasted effort if so.

4. **Tool routers (Family 5).** Out of scope; mention in positioning
   doc, leave to operators.

**Family 2 (semantic retrieval) is removed from the sequenced list.**
It is a category mismatch with the aggregator's deterministic-
composition identity, not a scale problem to defer. See §"Family 2"
above and §"Non-goals" below.

## Open questions before this becomes a spec

These are the decisions a follow-up specification has to answer.
They are not answered here.

**Catalog-shape questions:**

1. Is `catalog/list-tools` keyed by upstream server name, or flat
   across all upstreams with disambiguating namespace prefix?
2. Does `catalog/describe-tool` return PTC-Lisp signature spec, raw
   JSON Schema, or both?
3. What does the LLM see if it calls `tool/mcp-call` with an args
   shape that doesn't match `catalog/describe-tool`'s schema — pre-
   call validation in the aggregator, or upstream-side rejection?
   (Family 3's signature-validation feedback loop argues for pre-call
   validation; specifying the exact shape of that error envelope is
   in scope.)
4. **Catalog ops budget.** `catalog/*` calls don't hit subprocesses,
   but they shouldn't be unbounded — a runaway
   `(map describe-tool …)` over a 500-tool catalog is still expensive
   in interpreter time and result size. Proposed: a separate
   `--max-catalog-ops-per-program` cap (e.g. 20–50 default), distinct
   from `--max-upstream-calls-per-program`. Specify the cap, the
   error reason returned when it's hit, and whether the budget is
   per-program or per-server.
5. **Catalog refresh / staleness.** Long-running aggregator + upstream
   that gains tools post-boot = `(catalog/list-tools)` describes a
   stale fleet, or worse, `(catalog/describe-tool)` reports a tool
   that no longer exists. The current "rebuild only on PtcRunner
   restart" model is wrong here. Spec needs to commit to one of:
   (a) per-upstream TTL + opportunistic refresh on `tools/list`
   notifications from the upstream; (b) explicit
   `(catalog/refresh "server")` built-in operators can trigger;
   (c) both. Default behavior matters more than the knob.

**Size-aware default questions:**

6. **Where is the inline-vs-lazy threshold?** The recommendation says
   "~30 tools or ~5 KB rendered" — this needs an empirical anchor.
   Spec should cite measured token counts at known fleet sizes and
   pick the threshold based on inflection, not vibes. May want
   separate thresholds for tool count and byte size.
7. **Operator override.** A flag like `--catalog-mode {auto,inline,lazy}`
   that lets operators force either mode regardless of measured size.
   `auto` = the size-aware default.

**Scope questions:**

8. Is this aggregator-only, or does it also apply to the in-process
   `Plans/text-mode-ptc-compute-tool.md` story? The catalog problem
   is identical; sharing the API would be cleaner.
9. Does the plain (non-aggregator) `ptc_runner_mcp` server gain
   anything from `(catalog/*)` built-ins, or is this strictly an
   aggregator feature?

**Compatibility questions:**

10. With size-aware default, the inline catalog is *not* deprecated —
    it is the small-config path. Spec should make this explicit and
    not frame the change as "replacing inline." The migration story
    becomes "inline still works for small fleets; large fleets opt
    into lazy automatically."
11. How does this interact with the upstream allowlist work in
    Family 4 — single config file, two? Single, presumably.

**Validation questions:**

12. **Token-count metric.** Required but not sufficient. Measure
    `tools/list` token cost at 10 / 30 / 50 / 100 / 200 tools under
    inline, lazy, and (eventually) typed-bindings modes. Anchors the
    inline-vs-lazy threshold from Q6.
13. **Correctness-preserved metric.** Required, and currently punted
    in this doc. Without an A/B comparison on identical task suites,
    "lazy didn't break anything" is just an assertion. Need:
    (a) a fixed task suite that exercises 5–10 cross-server workflows
    of varying complexity; (b) program-correctness pass rate under
    inline vs. lazy with the same model and seed; (c) failure-mode
    breakdown (did the LLM forget to call `(catalog/*)`? Did it
    misuse a signature?). Without this, we can't honestly recommend
    the size-aware threshold from Q6 — we can only recommend the
    *cheaper* option, not the *correct* option. Belongs in the spec,
    not the implementation phase.
14. **Latency metric.** Token wins ignore wall-clock cost (see
    Family 1 tradeoff above). Measure end-to-end latency at the same
    fleet sizes, lazy mode minus inline mode. If the size-aware
    default is calibrated only on tokens, it will tilt toward lazy
    too aggressively for real users.

## Non-goals for this discussion

- **Semantic retrieval / RAG over tools (Family 2).** Out of scope as
  a category mismatch with the aggregator's deterministic-composition
  identity, not as a deferred feature. Operators who need it should
  put a router in front of the aggregator.
- **Becoming a tool router (Family 5).** Stays out of scope.
- **Becoming a gateway.** The aggregator advertises one tool. That
  identity is preserved across every option above.
- **Surfacing discovery as MCP meta-tools.** Even if Family 1 ships,
  it ships as PTC-Lisp built-ins inside `lisp_eval` — not as
  new MCP tools advertised on `tools/list`. The "exactly one tool
  advertised, exactly one approval prompt" property is non-
  negotiable.

## Citations

**Solution-family references:**

- Speakeasy — 100x token reduction with dynamic toolsets:
  https://www.speakeasy.com/blog/100x-token-reduction-dynamic-toolsets
- Speakeasy v2 — Reducing MCP token usage by 100x — you don't need
  code mode:
  https://www.speakeasy.com/blog/how-we-reduced-token-usage-by-100x-dynamic-toolsets-v2
- Anthropic — Code execution with MCP:
  https://www.anthropic.com/engineering/code-execution-with-mcp
- Cloudflare — Code Mode: give agents an entire API in 1,000 tokens:
  https://blog.cloudflare.com/code-mode-mcp/
- Cloudflare — Code Mode: the better way to use MCP:
  https://blog.cloudflare.com/code-mode/
- @cloudflare/codemode SDK rewrite changelog:
  https://developers.cloudflare.com/changelog/post/2026-02-20-codemode-sdk-rewrite/
- RAG-MCP paper (arXiv 2505.03275):
  https://arxiv.org/abs/2505.03275
- WRITER engineering — When too many tools become too much context:
  https://writer.com/engineering/rag-mcp/
- Lazy-load MCP tool definitions issue
  (anthropics/claude-code#11364):
  https://github.com/anthropics/claude-code/issues/11364
- Lazy Load MCP server: https://mcpmarket.com/server/lazy-load
- memoverflow/rag-mcp: https://github.com/memoverflow/rag-mcp
- OnlyCLI — MCP token trap benchmark:
  https://onlycli.github.io/OnlyCLI/blog/mcp-token-cost-benchmark/
- MCP Code Execution Enhanced — Progressive Disclosure Pattern:
  https://deepwiki.com/yoloshii/mcp-code-execution-enhanced/3.1-progressive-disclosure-pattern

**PtcRunner internal references:**

- [`Plans/positioning-mcp-aggregator.md`](positioning-mcp-aggregator.md)
  — peer comparison, feature signals, non-goals.
- [`Plans/ptc-runner-mcp-aggregator.md`](ptc-runner-mcp-aggregator.md)
  — current aggregator spec (catalog model lives here).
- [`mcp_server/README.md`](../mcp_server/README.md) §"What the LLM
  sees" — current inline-catalog behavior.

If solution-family citations drift as those projects evolve, update
this document — do not let drift accumulate silently into PtcRunner's
roadmap discussions.
