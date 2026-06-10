# PTC-Lisp Conversation Control Plane — Discussion Notes

**Status:** exploratory discussion notes, not a plan or requirements document.

This captures ideas from a design discussion about making `ptc_runner` usable
from PTC-Lisp itself, rather than requiring users to drop into Elixir code,
JSON config, or MCP client calls for common orchestration work.

The core question is: what would it look like if PTC-Lisp could inspect and
invoke the same low-level capabilities that Elixir and MCP callers already use,
including sessions, LLM calls, SubAgents, chat history, and prior debug traces?

## Why This Exists

The concrete goal is to make PTC-Lisp a durable working memory and control
surface for analysis tasks that are too large or iterative for one MCP tool call
or one LLM context window.

Simple MCP calls work well for request/response actions. They are weaker when a
task needs an evolving workspace: load data, define filters, save intermediate
hypotheses, ask an LLM about a bounded subset, refine the program, compare with
earlier results, and resume or fork the investigation later. Without a
Lisp-facing control plane, that state lives in client chat context, temporary
files, or opaque MCP session state.

For example, log analysis can become a shared programmatic workspace:

```clojure
(def errors (filter error? logs))
(def by-service (group-by :service errors))
(def suspicious (filter spike? by-service))

(chat/send "Explain the common failure pattern"
  {:vars ['suspicious]
   :sample-limit 20})
```

The useful product shape is not a vague agentic operating system. It is a
programmable, inspectable, resumable analysis session for debugging, log
analysis, data exploration, and agent replay.

## Starting Point

`ptc_runner` already has several adjacent pieces:

- `PtcRunner.Session` provides an embedding-friendly stateful Lisp REPL:
  memory plus bounded turn history.
- `mix ptc.repl` can evaluate PTC-Lisp, attach a capability prelude, and expose
  Clojure-style introspection forms such as `apropos`, `doc`, `meta`, `dir`,
  `ns-publics`, and `all-ns`.
- `ptc_runner_mcp` exposes stateless `lisp_eval` and stateful
  `lisp_session_*` MCP tools with ownership, TTL, inspection, forget/close, and
  transactional evaluation.
- `PtcRunner.SubAgent.chat/3` supports chat-shaped interaction with message
  history and, in PTC-Lisp mode, memory threading.
- SubAgents already support tool calling, builtin `llm-query`, tracing, prompt
  inventory, and debug surfaces.

Those pieces point toward a broader control-plane model: PTC-Lisp could be the
language used not only by an LLM inside a SubAgent, but also by humans and
preludes to create, inspect, compose, debug, and continue LLM conversations and
PTC sessions.

## Guiding Idea

Treat REPL sessions, LLM chats, SubAgent runs, MCP sessions, and historical
traces as related kinds of **conversation-like state machines**.

They differ in state shape:

- a Lisp REPL owns memory, `*1`/`*2`/`*3`, prints, and tool-call history;
- an LLM chat owns messages, model config, system prompt, and compaction policy;
- a SubAgent run owns prompt state, LLM turns, generated programs, tool calls,
  feedback, memory, and final output;
- an MCP session adds transport ownership, TTL, response projection, and
  cancellation semantics;
- a historical run artifact owns immutable event data that can be inspected,
  replayed, or forked into a new live session.

The common operations are similar:

```text
new / load / list / inspect / turn / eval-or-send / forget / close / fork
```

The important design boundary is that PTC-Lisp should manipulate capabilities
through explicit host-provided authority. Lisp should not own credentials,
provider policy, model registries, MCP ownership, or persistence rules.

## Capability Boundary

See also
[`capability-kernel-runtime.md`](capability-kernel-runtime.md), which now
separates the immediate borrowed-closure lifetime guard from the deferred
`RunEnv` typed-projection refactor. This control-plane document is downstream of
both pieces: do not implement these Lisp-facing APIs until the closed-context
guard is shipped and the `RunEnv` boundary has a committed reason to exist.

A useful primitive layer could be a host capability interface threaded through
`PtcRunner.Lisp.run/2`, similar in spirit to the existing tool executor and
discovery executor:

```elixir
PtcRunner.Lisp.run(source,
  host: %{
    ptc_eval: fn request -> ... end,
    session_new: fn opts -> ... end,
    session_eval: fn session_id, program, opts -> ... end,
    llm_call: fn request -> ... end,
    conversation_turn: fn conversation_id, input, opts -> ... end,
    agent_run: fn spec, input, opts -> ... end,
    inspect: fn target, opts -> ... end
  }
)
```

The exact shape is open. The design point is that Elixir embedding, the MCP
server, and `mix ptc.repl` could all provide the same logical capability
surface while enforcing their own ownership, persistence, limits, credentials,
and trace policy.

High-level Clojure-facing namespaces can then be prelude wrappers over this
lower-level host interface.

This primitive layer should not make a single provider, such as upstream tools,
responsible for running Lisp. Today the concrete cleanup is smaller:
`PtcRunner.Upstream.Eval` is already a thin projection over `PtcRunner.Lisp.run/2`;
the immediate hardening is to make borrowed upstream closures fail closed after
their `RunContext` closes. A future `PtcRunner.Lisp.RunEnv` may make provider
state projection typed and explicit once this control plane is no longer
exploratory. A shared runtime kernel may generalize that only after more
lifecycle-bearing providers justify it.

## Relationship to Capability Profiles

[`capability-prelude-discovery.md`](capability-prelude-discovery.md) explores
the authority/model side: capability profiles, providers, runtimes, grants,
effects, and descriptors.

This document is the runtime control-surface side. Conversation APIs should use
the capability/profile descriptor model to discover and describe available
tools, SubAgents, upstream operations, model affordances, and sandbox
capabilities. They should not create authority-bearing profile state or define
endpoints, credentials, grants, model policy, or provider configuration from
ordinary user-space Lisp.

In that split, `ptc/inspect`, `ptc/invoke`, `ctx/*`, `agent/*`, `chat/*`, and
historical `run/*` or `session/*` APIs are consumers of host-provided
capabilities. The host runtime remains responsible for permissioning,
redaction, persistence, limits, and transport policy.

LLM aliases follow the same rule. Runtime Lisp should use aliases and roles
defined by the selected capability profile:

```clojure
(llm/call {:model :haiku
           :messages [{:role :user
                       :content "Summarize this"}]})

(def chat
  (chat/session {:model :chat
                 :system "You are helping inside a PTC-Lisp REPL."}))

(agent/run {:prompt "Analyze these rows"
            :llm :code
            :output :text})
```

Ordinary user-space Lisp should not define providers, set API keys, configure
Bedrock/OpenRouter/OpenAI-compatible credentials, or grant model access. It can
inspect safe descriptors and call allowed aliases:

```clojure
(llm/models)
(meta 'llm/haiku)
;; {:alias :haiku
;;  :provider :openrouter
;;  :model "anthropic/claude-haiku-4.5"
;;  :credential? true
;;  :secret-visible? false
;;  :effects [:llm-call]}
```

This should preserve the existing Elixir-side LLM callback primitive. A model
alias may ultimately point to a direct function callback, a
`PtcRunner.LLM.callback/2` adapter wrapper, or a stateful provider-backed
client. Any future capability runtime would compose aliases, grants, budgets,
tracing, and descriptors around those callbacks; it should not replace the
simple callback API that makes SubAgent tests and custom providers easy.

## Possible Lisp Surface

Low-level primitives might live under a small `ptc` namespace:

```clojure
(ptc/eval "(+ 1 2)")
(ptc/session {:history-depth 10})
(ptc/eval-in session "(def x 41)")
(ptc/inspect session)
(ptc/capabilities)
(ptc/invoke 'tool/search {:query "x"})
```

Higher-level prelude namespaces could provide friendlier APIs:

```clojure
(ctx/keys)
(ctx/meta)
(ctx/sample :orders)
(ctx/schema :orders)

(repl/vars)
(repl/history)
(repl/source 'high-value?)

(llm/call {:model "haiku"
           :messages [{:role :user :content "Summarize this"}]})

(llm/models)
(meta 'llm/haiku)

(chat/session {:model "haiku"
               :system "You are helping inside a PTC-Lisp REPL."})
(chat/send chat "Explain the last result")
(chat/code chat "Write a PTC-Lisp function for this")

(agent/run {:prompt "Summarize these rows"
            :context {:rows vip-orders}
            :output :text})
(agent/session {:system "You are a data analyst."})
(agent/chat analyst "Inspect the current context")
(agent/inspect analyst)
```

The authoring target should be ordinary data. One-shot calls can return maps
with status, return value, usage, tool calls, trace IDs, messages, memory, and
errors. Long-lived state should probably be represented by opaque handles or
tagged maps rather than raw BEAM pids or structs.

## REPL + Chat

One promising use case is making `mix ptc.repl` both a Lisp REPL and an LLM chat
workbench.

Example interaction:

```clojure
(def rows data/orders)

(defn high-value? [o]
  (> (:total o) 1000))

(def vip-orders (filter high-value? rows))

(chat/send "Summarize vip-orders and suggest next analysis")
(chat/code "Write a function that groups vip-orders by :region")
(ptc/eval (chat/code "Define that function and test it"))
```

The chat should not implicitly receive the entire REPL state. Instead the REPL
should expose explicit, bounded context projection:

```clojure
(chat/send "Explain this"
  {:include [:last-result :vars]
   :vars ['vip-orders]
   :sample-limit 5})

(ptc/repl-context {:include [:vars :history :prints]
                   :vars ['vip-orders]})
```

This keeps chat memory separate from Lisp memory:

- chat history may contain natural language, failed attempts, model chatter,
  and compaction summaries;
- Lisp memory should stay precise, inspectable, and programmatic.

## README Shape

If the main interface becomes PTC-Lisp, the root `README.md` could lead with
PTC-Lisp examples and mention Elixir as a first-class host/integration layer
rather than as the primary authoring surface.

Sketch:

````markdown
# ptc_runner

`ptc_runner` runs safe PTC-Lisp programs for working with data, tools, LLMs,
SubAgents, and conversations.

PTC-Lisp is the main interface. Elixir applications use `ptc_runner` to provide
context, tools, credentials, limits, persistence, and deployment policy.

## Try It

```sh
mix ptc.repl
```

```clojure
(+ 1 2)
(map inc [1 2 3])
(doc 'filter)
(apropos "json")
```

## Work With Context

```clojure
(ctx/keys)
(ctx/sample :orders)

(def vip-orders
  (filter #(> (:total %) 1000) data/orders))

(count vip-orders)
```

## Call Tools

```clojure
(dir 'crm)
(doc 'crm/get-user)

(crm/get-user "user-123")
(tool/call 'observatory/list-traces {:org-id "acme" :limit 20})
```

## Ask an LLM

```clojure
(def chat
  (chat/session {:model "haiku"
                 :system "You are helping inside a PTC-Lisp REPL."}))

(chat/send chat "Summarize vip-orders")
(chat/code chat "Write a function that groups these by :region")
```

## Run a SubAgent

```clojure
(agent/run {:name "analyst"
            :prompt "Analyze the high-value orders"
            :context {:orders vip-orders}
            :output :text})
```

## Debug Previous Runs

```clojure
(def r (run/load :latest))
(run/error r)
(run/program r :failed-turn)

(def s (session/from-run r {:before :failed-turn}))
(session/eval s "(ctx/keys)")
```

## Use From Elixir

Elixir is the host integration layer. Use it to provide context, tools, LLM
adapters, capability profiles, tracing, and application-specific persistence.

```elixir
tools = %{"search" => &MyApp.Search.run/1}
context = %{"orders" => MyApp.Orders.recent()}

PtcRunner.Lisp.run(source, context: context, tools: tools)
```

For agentic workflows, Elixir can still construct and run SubAgents directly,
or expose them as PTC-Lisp capabilities:

```elixir
agent = PtcRunner.SubAgent.new(prompt: "Analyze {{topic}}", output: :text)
PtcRunner.SubAgent.run(agent, context: %{topic: "orders"}, llm: "haiku")
```
````

The useful README pressure test: if common workflows cannot be shown primarily
as PTC-Lisp, then the Lisp-facing control surface is not complete enough yet.

## Introspection as a Shared Interface

Introspection should be available to humans, LLMs, and ordinary Clojure
functions through the same data model.

Existing Clojure-style discovery forms should remain central:

```clojure
(apropos "agent")
(doc 'agent/run)
(meta 'agent/run)
(dir 'agent)
(ns-publics 'agent)

(apropos "orders")
(doc 'data/orders)
(meta 'data/orders)
```

Potential structured introspection APIs:

```clojure
(ctx/current)
(ctx/keys)
(ctx/meta)
(ctx/get :orders)
(ctx/sample :orders)
(ctx/schema :orders)
(ctx/describe :orders)

(repl/vars)
(repl/var-meta 'vip-orders)
(repl/source 'high-value?)
(repl/history)

(agent/capabilities analyst)
(agent/context analyst)
(agent/memory analyst)
(agent/messages analyst)
(agent/inspect analyst)
```

The exact names are open. The key idea is that prompt inventory should not be
prompt-only. If an LLM can read that a capability exists, PTC-Lisp code should
also be able to inspect it in a bounded, structured way.

## SubAgent as a PTC-Lisp Primitive

SubAgent should probably become invokable from PTC-Lisp as a core capability,
not only as Elixir structs or JSON/MCP configuration.

Possible one-shot form:

```clojure
(agent/run {:name "analyst"
            :prompt "Analyze {{topic}}"
            :output :ptc-lisp
            :tools [:inherited]
            :signature "{summary :string}"}
           {:topic "orders"})
```

Possible stateful form:

```clojure
(def analyst
  (agent/session {:system "You are a data analyst."
                  :output :text}))

(agent/chat analyst "Inspect the current context")
(agent/chat analyst "Now compare by region")
(agent/inspect analyst)
```

Potential return shape:

```clojure
{:status :ok
 :return ...
 :memory {...}
 :messages [...]
 :usage {:duration-ms 812}
 :tool-calls [...]
 :trace-id "..."}
```

Important open question: how much of the parent environment should a child
SubAgent inspect or inherit? A likely answer is explicit projection:

```clojure
(agent/run analyst
  {:topic "orders"}
  {:inspect [:context :vars :tools]
   :context-keys [:orders :customers]
   :vars ['vip-orders]})
```

## Historical Sessions and Debug Artifacts

For debugging, live sessions are not enough. Previous `ptc.repl` sessions,
SubAgent runs, failed turns, and MCP evaluations should be queryable as durable
artifacts.

Possible APIs:

```clojure
(session/list)
(session/load "2026-06-08T10-32-11Z")
(session/inspect s)
(session/turns s)
(session/turn s 4)
(session/context s 4)
(session/messages s 4)
(session/memory s 4)
(session/replay s 4)
(session/continue s)
```

For SubAgent traces:

```clojure
(run/list {:kind :subagent})
(run/load "trace-id")
(run/turns r)
(run/inspect r {:view :summary})
(run/inspect r {:view :messages})
(run/inspect r {:view :tool-calls})
(run/inspect r {:view :lisp})
(run/inspect r {:view :failure})

(run/prompt r :failed-turn)
(run/llm-request r :failed-turn)
(run/llm-response r :failed-turn)
(run/program r :failed-turn)
(run/result r :failed-turn)
(run/error r :failed-turn)
(run/tool-calls r :failed-turn)
(run/memory r :failed-turn)
(run/context r :failed-turn)
(run/feedback r :failed-turn)
```

A useful debugging workflow:

```clojure
(def r (run/load :latest))
(run/error r)
(run/program r :failed-turn)
(run/context r :failed-turn)

(def s (session/from-run r {:before :failed-turn}))
(session/eval s "(ctx/keys)")
(session/eval s "(fixed-code-here)")
```

Continuing from history should probably fork rather than mutate the original:

```clojure
(run/fork r {:from-turn 4})
(session/from-run r {:before-turn 5})
```

The historical artifact should be an event log or normalized trace record, not
a serialized live process. It should store enough to reconstruct useful debug
state:

- source/program per turn;
- context projection;
- memory before/after;
- turn history;
- LLM messages, requests, and responses;
- tool calls and results;
- failure data and feedback;
- prompt inventory and prelude identity;
- model/tool/runtime metadata;
- trace IDs and timestamps.

## Limits and Safety Questions

Several risks need explicit design if these ideas move toward implementation:

- nested PTC evals should inherit or consume parent timeouts, heap limits, tool
  call limits, and mission deadlines;
- LLM calls from Lisp need model allowlists, rate limits, and token budgets;
- `agent/run` from Lisp must not become an escape hatch around SubAgent turn
  limits or tool permissions;
- introspection must be scoped, especially for credentials, upstream runtime
  config, raw messages, and large context values;
- auto-evaluating model-generated code should be a visibly explicit operation,
  separate from ordinary chat;
- historical replay should distinguish exact replay, best-effort replay, and
  forked continuation, since external tools and model responses may not be
  deterministic;
- durable artifacts need redaction and output limits comparable to MCP response
  shaping and trace payload policy.

## Open Design Threads

- Is the primitive layer best modeled as `ptc/inspect` and `ptc/invoke`, with
  all friendly APIs implemented as prelude wrappers?
- Should conversations be a public Elixir abstraction such as
  `PtcRunner.Conversation`, or should the abstraction remain internal until the
  Lisp/MCP surfaces clarify?
- Should `mix ptc.repl` support chat through command syntax, Lisp functions, or
  both?
- What is the right persisted artifact format for previous REPL sessions and
  SubAgent runs?
- How should `apropos`, `doc`, `meta`, `dir`, and `ns-publics` merge local
  builtins, prelude exports, upstream tools, SubAgent capabilities, historical
  artifacts, and live conversation handles?
- What parts of a parent REPL or SubAgent context should a child SubAgent be
  able to inspect by default?

These notes intentionally avoid locking in names or milestones. The main idea
to preserve is that PTC-Lisp can become the inspectable, programmable control
plane for `ptc_runner`, while host runtimes remain responsible for authority,
credentials, limits, persistence, and transport policy.
