# Tool-compiler logbook

Append-only. Each entry records what was tried, what the numbers were, and what
the result changed. Written so an agent reading it later has the same context a
person would.

## The question

Does compiling a domain-specific tool from observed usage pay for itself,
against a model calling the raw upstream tools itself?

Arm A is the control: six raw `ptc-web` page tools, no domain knowledge. Arm B
replaces the mission component with something compiled from Arm A's evidence.
Same tasks, same metrics.

## Standing constraints

- **Build every step so an agent on the ptc harness could run it**, not only a
  coding agent with a shell. Inputs and outputs are data. Starting servers,
  `npm install` and git stay in the lab driver; reading evidence, proposing a
  recipe, validating it and emitting a candidate must be expressible as a ptc
  workflow.
- **The compiled artifact is a recipe as data**, not a generated program, for
  the same reason. `repair-recipe.schema.json` in `examples/adaptive-web-parser`
  is the shape to follow.
- **The accept gate is the held-out page.** A recipe is accepted only if it
  extracts the right records from the page it was learned on *and* from a page
  with a different DOM shape. Borrowed from the same example.

## 2026-09-16 — Arm A exists and is measured

Built `fixture.mjs`, `ptc-host.json`, `passthrough/`, `run.mjs`.

The fixture extends the `adaptive-web-parser` quotation board: `/quotes` and
`/held-out` carry the same two records in different DOM shapes, every page has a
decoy `.speaker` in the nav, and `/ledger` hides three records behind forty
filler rows so one `page_read` cannot return the page.

Three runs, nine attempts, **zero correct answers**. Representative run:

| page | status | tool calls | model calls | input tokens | records | correct |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `/quotes` | turn limit | 0 | 25 | 90,972 | – | no |
| `/held-out` | ok | 4 | 11 | 30,334 | 10 | no |
| `/ledger` | ok | 23 | 25 | 190,109 | 60 | no |

Earlier runs reached 16 and 36 tool calls and 95k input tokens on `/quotes`, and
once spent 24 model turns making zero page calls before the run closed on a
limit. Failure modes split between exhausting the turn budget and returning the
nav decoy plus the filler rows: 10 records for a 2-record page, 60 for a
3-record page.

**What this changes.** At 0 of 9, Arm A is not yet a cost baseline; it is a
reliability result. Arm B beating it is not in question. If a cost comparison is
wanted, Arm A has to succeed sometimes, which means a stronger model or more
turns, not a hint about selectors: the selector is the domain knowledge under
test.

## Findings worth keeping

- `ptc-web` ships **six** tools, not the four `examples/adaptive-web-parser`
  maps. `page_read` (paginated markdown) and `page_find` are what make the
  domain noisy, and the example never exposes page content to its model at all.
- Metrics belong to the envelope, not to arithmetic over traces.
  `execution.usage.capability_calls` counts every call and `llm_spend` every
  token. A run closed by a limit reports `llm_spend.state: "incomplete"`, and
  reporting zero there understates the arm; the harness prints `n/a`.
- The signature grammar has no `:vector`. Arrays are `[{...}]`. Two compile
  failures came from that, which is the language giving exactly the early,
  located feedback the design argues for.
- **Gap, filed as backlog, not worked around:** nothing lists an MCP
  installation's tool catalog with schemas. Discovering `ptc-web`'s six tools
  meant grepping its npm build, which an agent on the harness cannot do.

## 2026-09-16 — Arm B exists, with a hand-written recipe

`compiled/` pins the recipe as data (`article.entry`, `p.words`,
`span.speaker`) and calls open, capture, extract, close. No agent loop, no
model: `installation_config_digests` for that manifest names only `web`.

| arm | tool calls | model calls | input tokens | micro USD | correct |
| --- | ---: | ---: | ---: | ---: | --- |
| passthrough | 61 | 59 | 196,098 | 5,527 | 0/3 |
| compiled | 12 | 0 | 0 | 0 | 3/3 |

One recipe covers all three pages, including the nested `/held-out` shape, and
excludes the nav decoy, so the held-out gate passes by construction.

**The recipe was written by hand.** The measurement therefore says what a
compiled tool is worth if one can be found, not that one can be found. That is
the next arm.

## The blocker for automatic compilation

`ptc-web` never exposes markup. `page_capture`'s preview is
`representation(snapshot, 'text', 'document').content.slice(0, 1000)`, plain
text, and `page_read` returns markdown or text. Nothing returns HTML.

So a compiler cannot read the DOM and write selectors, which is why
`examples/adaptive-web-parser` hardcodes the page HTML in `evidence.clj`. It has
no other option.

**Consequence for the design, and it is a better one.** The compiler must learn
by probing rather than by reading source: use `page_read` to learn the target
strings, propose a candidate recipe, apply it with `page_extract`, compare the
returned records against the strings already known, and iterate. The tool's own
behaviour is the oracle. That is closer to "spin up an environment where it
tests the tool and pokes at it" than reading markup would be, and it stays
expressible as data in, data out.

**Gap, filed as backlog:** no `ptc-web` tool exposes a structural view of a
page, so selector authoring is blind. Second item after the missing tool-catalog
command.

## Mechanism notes

- `kernel/` must be declared: the workflow component needs
  `dependencies: ["kernel"]` and a `{"library": "kernel"}` entry, or the bundle
  fails with `unknown_namespace`.
- `kernel/eval-with` returns an outcome, not a value. Returning it directly
  fails the result contract at `/records`; unwrap `:outcome`/`:value` first, as
  `examples/adaptive-web-parser` does.
- Arm A's `/ledger` now ends on `run_duration_ms` 120000 rather than the turn
  limit. Both are legitimate Arm A outcomes and the harness records which.

## 2026-09-16 — Arm C compiles a recipe, and it passes the gate

`compiler/` is a ptc workflow. Its mission exposes two probes and nothing else:
`read-text`, to learn what records a page contains, and `try-recipes`, to apply
candidate selectors. It returns a recipe as data. `compile.mjs` writes that
recipe into `compiled/ptc.json` mission data, and the compiled arm is then
re-verified independently: the compiler's own claim is not trusted.

**It worked.** The discovered recipe, verified on all three pages:

```json
{"container": "article", "text_selector": "p", "author_selector": "span"}
```

| stage | tool calls | model calls | input tokens | micro USD | correct |
| --- | ---: | ---: | ---: | ---: | --- |
| Arm A, per pass over 3 pages | 61 | 59 | 196,098 | 5,527 | 0/3 |
| Arm C, once | 101 | 11 | 52,859 | 2,615 | — |
| Arm B, per pass over 3 pages | 12 | 0 | 0 | 0 | 3/3 |

Compiling costs under half of a single passthrough pass and every pass after it
is free of model cost, so it repays in less than one use while turning a task
the raw tools never completed into one that always completes.

The compiler found a **more general** recipe than the hand-written one
(`article`/`p`/`span` rather than `article.entry`/`p.words`/`span.speaker`). It
passes because the nav decoy sits outside any `article` and the filler rows sit
outside one too. It is also more fragile than the hand-written version against
pages that put other prose inside an article, which is an argument for the
accept gate covering more held-out shapes rather than for trusting the model.

### Batching the probe was the unlock

The first attempt opened and captured a page per candidate: 35 page loads for 30
candidates, and the run died with its `limit-exceeded` event itself dropped by
trace retention. Replacing `try-recipe` with `try-recipes`, which applies many
candidates to one immutable snapshot, moved the ratio to 10 page loads for 81
candidates. That is the whole PTC argument appearing inside the compiler: one
program, many tool calls, one page load.

### Friction worth reporting

- Two separate ceilings default to 120000 ms and are raised separately:
  `limits.run_duration_ms` and `limits.workflow_timeout_ms`. Raising the first
  and re-running only bought the second error.
- `--inspect FILE` accepts any filename, but `ptc transcript` requires the
  canonical `<run_ref>.ptcins` under `--inspection`, and refuses when `--traces`,
  `--inspection` and `--private-output` are not physically separate directories.
  Three refusals before the first useful read.
- A run that drops trace events cannot be certified by `ptc transcript` at all,
  and the dropped set included the one `limit-exceeded` event that explained the
  failure. The envelope's `execution.usage` was the only surviving account.

## How the recipe was found, turn by turn

Read out of the run's own inspection record, not reconstructed:

```console
ptc repl --profile private-run-analysis-v2 --run <run_ref> \
  --resource traces=<dir> --resource inspection=<dir> \
  --private-unattended --format jsonl \
  -e '(analysis/read "<run_ref>" {"collection" "turns" "limit" 12})'
```

The eleven turns of `cmd-3dz31p7hv546vtps1sn0jh7k3w`:

```clojure
turn 1  (println (lab.probe/read-text ".../quotes"))
turn 2  (println (lab.probe/read-text ".../held-out"))
turn 3  (lab.probe/try-recipes ".../quotes"
          [{"container" "blockquote" "text_selector" "p"     "author_selector" "footer"}
           {"container" ".quote"     "text_selector" ".text" "author_selector" ".attribution"}
           {"container" "div.quote"  "text_selector" "p"     "author_selector" "cite"} ...])
turn 4-7  narrows to `.entry` and `article` containers, tries positional
          selectors (p:first-child, p:nth-child(2), p:first-of-type),
          alternating between the two pages
turn 8    ... {"container" "article" "text_selector" "p" "author_selector" "span"} ...
turn 9  (lab.probe/try-recipes ".../quotes"   [{article p span}])
        (lab.probe/try-recipes ".../held-out" [{article p span}])
turn 10 (return {"container" "article" "text_selector" "p" "author_selector" "span"})
```

It opened with conventional quotation markup that does not exist on this
fixture (`blockquote`/`footer`, `.quote`/`.attribution`, `cite`), then worked
down to what the pages actually contain, and at turn 9 re-applied the single
finalist to both pages before committing. Input tokens per turn ran 1,495 to
9,209; the accumulating history is where the compile cost goes.

### Who did what

- The **model** (`openrouter:deepseek/deepseek-v4-flash`) performed the search.
- **I** wrote the compiler application: the prompt, the two probes, the result
  contract, the limits. The selectors it found are not the ones I had written by
  hand, which were narrower.
- The **runtime** confined the search to two callable functions and one grant,
  evaluated each program, returned records as feedback, enforced the result
  contract, and recorded every turn.
- The **3/3 is not the model's self-report.** After it returned, the driver wrote
  the recipe into `compiled/ptc.json` mission data and re-extracted all three
  pages through a manifest that installs no model at all.

A fair sentence: a model, searching inside a bounded run over a probe surface
written for it, found a recipe, and an independent run verified it.

### Discrepancy

`analysis/runs` reported `llm_calls: 8` with `truncated: true` for this run,
while both the envelope's `capability_calls` and the `turns` collection
(`item_count: 11`) say eleven. The summary view undercounts.
