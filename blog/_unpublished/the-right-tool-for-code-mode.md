---
layout: default
title: "The Right Tool for Code Mode"
---

# The Right Tool for Code Mode

*Letting an LLM write code to drive your tools is the right idea. The language almost everyone reaches for is the wrong one.*

---

A while back I built my own personal assistant and wired it to my email, calendar, and phone over MCP. One of the first things I asked was simple: "show me the last 10 emails."

That was already enough to feel the problem. Email bodies are long, quoted threads are longer, and every message the tool returned was now sitting in the model's context. The model had not done any real work yet. It had just fetched data, and the context window was already being spent.

Then I asked for something more useful: "go through my mail, suggest a few categories, and give me some statistics." Categorizing mail is ordinary data work. You look at subjects and senders, group by pattern, count things. But the model tried to do it by reading messages one at a time in its head. The context filled up, the answers got vague, and the counts were wrong.

Some of that was on my Gmail MCP. But the failure pointed at something deeper: the model was being asked to *be the computer*, and it is not good at that. It is good at deciding *what* to compute. Those are different jobs, and I had handed it the wrong one.

That gap is the reason I built the agentic framework [ptc_runner](https://github.com/andreasronge/ptc_runner), and lately a standalone MCP server on top of it. This post is about why I think the popular answer to that gap reaches for the wrong tool, and what a better one looks like. It also changed how I design tools in the first place, which turned out to be the lesson I keep coming back to.

## Code mode is having a moment

The idea going around is a good one. Instead of the model calling tools one at a time and dragging every result back into the conversation, it writes a small program. The program calls the tools, processes the results where they sit, and returns only the part that matters.

Cloudflare shipped a version of this and called it [Code Mode](https://blog.cloudflare.com/code-mode/): they convert MCP tools into a TypeScript API and let the model write TypeScript against it. Anthropic made a closely related case in [Code execution with MCP](https://www.anthropic.com/engineering/code-execution-with-mcp): let the agent write code so the intermediate results stay in the execution environment, and only the part you choose to return ever reaches the model. Different languages, same core move: stop making the model the runtime, and let it write code instead.

The direction is right. I have been convinced of that for a while. Where I part ways is the very next decision, the one that gets made almost by reflex: *which language does the model write?*

Cloudflare's reasoning is that models write TypeScript and JavaScript better than they navigate hand-rolled tool calls, so you should meet them where they are strong. That is true as far as it goes. But "the model knows this language well" is optimizing for the wrong thing.

## The job is not what those languages are for

Think about what the code actually is in this setting. It is short. It is thrown away the moment it runs. It was written by something that cannot be fully trusted, and it executes on your machine or in your account. When it goes wrong, what you need most is a clear signal back so the model can fix itself on the next attempt.

That is a very specific job: run many small, disposable, untrusted snippets, safely, with feedback good enough to recover from. Python and JavaScript were not designed for that. They were designed for people writing real programs they intend to keep. They bring their whole surface area along: imports, file access, network calls, a vast standard library, a thousand ways to do almost anything.

When the author is an LLM, all of that reach turns into something you have to manage. You can make it safe. People do it every day, with containers, V8 isolates, and hardened interpreters that strip capabilities back out. But look at what that work is: it lives outside the language. You pick a tool that can do anything, then spend real engineering making sure it cannot. The constraint you actually wanted is not part of the tool. It is bolted on, which means it is something you own, something that can be misconfigured, and something that is never quite finished.

That is the real cost of a general-purpose language here. Not that it is unsafe, but that you pay, continuously, to remove power you never wanted in the first place.

There is a quieter cost too. A big language gives the model a big space to be subtly wrong in. More syntax, more scoping rules, more ways to write something that parses fine and means the wrong thing. For one-shot generation that has to run untrusted, that surface is working against you.

## Make the language the sandbox

The alternative is to stop fighting a general-purpose language and pick one shaped for the job.

ptc_runner runs a small Clojure-like language called PTC-Lisp. There is no filesystem access, no network access, no `import`, no `eval`. Those capabilities are not switched off behind a flag. They simply do not exist in the language, so there is nothing to sandbox away. The constraint is not a wrapper around the language. It is the language.

Every program runs in its own lightweight BEAM process (the runtime behind Erlang and Elixir) with a wall-clock limit and a memory limit. If a program loops or balloons, that one process is killed and the model is told why, in terms it can act on. Errors are written to be recovered from, not to look like a stack trace. The model reads the feedback, adjusts, and tries again, the way you would at a REPL.

For readers wondering how much "Clojure-like" means in practice, the generated [namespace coverage index](https://github.com/andreasronge/ptc_runner/blob/main/docs/conformance/index.md) tracks supported Clojure namespaces, curated Java compatibility targets, and PTC-specific extensions.

This does not seem to require a frontier model. In a small [PTC-Lisp generation benchmark](https://github.com/andreasronge/ptc_runner/blob/main/docs/benchmark-eval.md), Gemini 3.1 Flash Lite and Claude Haiku 4.5 each passed 149 of 150 executions, which is enough for the practical point here: cheaper models can use the language reliably.

The core path through the MCP server is a single tool, `lisp_eval`, that takes a PTC-Lisp program and optional input (sessions and diagnostics add a few more when you want them). Any MCP client can point at it: Claude Desktop, Cursor, Cline, Claude Code. You do not write Elixir, and you do not host a Python runtime. You run a binary and add it to your client config. The fact that there is a 30-year-old battle-tested VM doing the isolation underneath is an implementation detail you never have to touch.

## A small example

Let me show the failure that made this concrete, and then the fix.

I set up an upstream MCP server I will call `observatory`, holding mock observability traces. It exposes three plain read tools: `list_traces`, `get_trace`, and `get_trace_steps`. I connected Claude Code straight to it and asked the first question that came to mind: "find the org-acme production spend spike."

It pulled the traces into context, read through them, and gave me an answer with a percentage in it. The percentage was wrong.

I want to be careful here, because it would be easy to dress this up. This was mock data and a single recorded run, not a benchmark. I am not claiming a precise win rate. What struck me was how *ordinary* the question was and how *easily* it went wrong. This was the very first thing I asked, not some adversarial edge case. The model was not lying. It was doing mental arithmetic over a table it had to read, and it slipped, exactly the way I would if you asked me to sum a column by eye.

Then I asked the same question through ptc_runner's code mode. Instead of reading the traces, the model wrote a few lines that fetched them and computed over them:

```clojure
;; Pull the traces once. They stay inside the sandbox, not in the context window.
(def traces
  (get (:value (tool/mcp-call {:server "observatory"
                               :tool "list_traces"
                               :args {:org_id "org-acme"
                                      :environment "production"}}))
       "traces"))

(defn cost [t] (json/parse-string (get t "total_cost")))
(defn day  [t] (subs (get t "started_at") 0 10))

;; Group by day, sum the cost, sort. Hand back only the small table.
(sort-by :day
  (map (fn [pair]
         (let [d  (first pair)
               ts (second pair)]
           {:day d :n (count ts) :cost (reduce + 0 (map cost ts))}))
       (group-by day traces)))
```

The sum was computed, not estimated, so the answer was right. From there the model drilled into the one expensive trace, found eight loop iterations that re-sent the full transcript each time, and explained the spike. Each step was another short program against the same primitive tools.

The other thing worth reporting is how little data crossed back into the context window. Across that investigation, roughly 27,800 tokens of trace data were fetched and processed inside the sandbox, while only about 740 tokens of results came back into the model's context. That is around 37 times less data in the window than if the traces had been read directly. The honest caveat: those are figures for data moving through the runner, not the full conversation cost, which the runner cannot see. But the shape of it is the whole point. The bulk stayed where bulk belongs, in memory, and the model only ever saw the conclusions.

The efficiency is the easy thing to notice. It is not the most interesting thing in that example.

## Code mode should feel like a REPL

The REPL part matters more than I expected. Investigations are naturally stateful. You define `cost`, bind `traces`, compute `by-day`, inspect the spike, and then ask the next question using the same small workspace. If every code-mode call is a fresh sandbox, the model has to recreate that workspace over and over, or push more of it back into the context window.

That is awkward with a general-purpose runtime. Keeping a pool of stateful Python or JavaScript sandboxes around means keeping imports, heaps, event loops, and capabilities alive too. Cold-starting them is simpler, but then you lose the REPL shape.

ptc_runner sessions are deliberately smaller. Definitions persist across calls, but each eval still runs with heap and timeout limits. The model gets continuity without owning a long-lived Python or JavaScript process. That is the performance story as much as the ergonomics story: the model gets a small workspace outside the context window, so it does not have to rebuild the same world every time it asks the next question.[^perf]

![Stateful sandboxed REPL sessions in ptc_runner](./assets/images/mcp_sandbox_repl.png)

## Tool lists are context too

The same idea applies before the first tool call. MCP tool lists can get large fast. Every server brings names, descriptions, schemas, examples, and response shapes, and most of that is irrelevant to the task in front of you. If all of it is pushed into the prompt up front, tool discovery becomes another version of the context-window problem.

ptc_runner can make the tool catalog part of the runtime instead. A program can ask which upstream servers exist with `(catalog/list-servers)`, search for a relevant capability with `(catalog/search-tools "calendar")`, list one server's tools with `(catalog/list-tools "calendar")`, and pull the details for a single tool with `(catalog/describe-tool "calendar" "search_events")`. In a session, that means the model can explore the available tools the same way it explores the data: ask for the next small piece of structure, bind what it learned, and continue. The model does not need to carry every possible tool in its head just in case one of them matters.

## The part that changed how I build these systems

Go back to that server for a second. The `observatory` server is dumb. It exposes `list_traces`, `get_trace`, and `get_trace_steps`, and that is all. It knows nothing about spend spikes. The spike detection did not live in a tool. It lived in code the model wrote on the spot, for that one question.

That is the shift I did not expect, and it is the part I would most want a fellow builder to take away.

Before code mode, you designed MCP tools for the questions you thought people would ask. It works a bit like RAG. With RAG you have to anticipate the questions up front to tune your chunking and your embeddings, and when the questions change, your retrieval is suddenly wrong. MCP tool design can fall into a similar trap. You decide each tool's granularity, you shape its responses, you paginate it just so, and then you sit and watch the responses come back and tweak the design. You are optimizing in advance for usage you are only guessing at.

Code mode loosens that grip. If the client can write code against your tools, it can use them in an exploratory way: run something, look at the shape, run the next thing based on what it saw. LLMs are genuinely good at that loop, because it is the pattern they have seen endlessly in notebooks and shell sessions.

So you do not have to front-load all the cleverness into your tools anymore. You can ship simple, boring servers that expose primitives, and let the code-mode client compose the logic per question. The intelligence moves to the edge, into generated code that is written for the moment and discarded after. For anyone designing agentic systems, that is a real simplification: stop pre-optimizing tools for imagined workloads, ship the primitive, and let the questions find their own programs.

## Simplify until it disappears

If there is a bias running underneath all of this, it is that I like removing things.

The language is small on purpose. The servers can be dumb on purpose. Recently a customer asked me to design an MCP server around one of their tools, and I caught myself asking whether they needed MCP at all. The tool was already an HTTP API. If its responses carried the next available actions as links or forms, the old REST/HATEOAS idea, then a model that can write code might not need a separate protocol layer describing every action up front. It could start from one URL, inspect the representation, and follow the affordances that matter for the task.

That is a thought for another day, but it points the same way as everything else here: a smaller language, simpler servers, fewer layers between the model and the data.

Code mode is the right idea. The win does not come from handing the model the biggest, most familiar language and then spending months caging it. It comes from picking a tool actually shaped for the job, and from being willing to leave things out. I like making things that are no longer needed go away.

---

*ptc_runner is a 0.x library under active development. Expect bugs and breaking changes while the design settles.*

*[ptc_runner on GitHub](https://github.com/andreasronge/ptc_runner) · [Hex package](https://hex.pm/packages/ptc_runner) · [Documentation](https://hexdocs.pm/ptc_runner)*

[^perf]: Local development numbers on an Apple MacBook Pro M1, not a portable benchmark: loopback HTTP MCP, no upstream calls, warning logs, Python `urllib` client. With a reused session, evals stayed cheap: `(+ 1 2)` was about 1.5 ms p50 at concurrency 1 and about 3,500 evals/sec at concurrency 16; `(reduce + 0 (range 10000))` was about 2.8 ms p50 and about 3,200 evals/sec. Without session reuse, each eval paid the full MCP setup/teardown path (`initialize -> initialized notification -> lisp_eval -> DELETE`), dropping tiny-eval throughput to about 1,000 cycles/sec at concurrency 16 with p50 end-to-end latency around 15 ms.
