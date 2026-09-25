---
program: tool-compiler
experiment: tool-compiler/000
issue: 2017
tag: research/tool-compiler/000
kinds: [measure, change]
hypotheses: []
model: openrouter:deepseek/deepseek-v4-flash
replay: none
tags: [tool-compilation, ptc-web, restricted-baseline, deepseek]
---

# Tool-compiler 000: compiling a web-extraction recipe from probing

Date: 2026-09-16 to 2026-09-25. An exploratory maintainer lab, not a
registered program: it has no predeclared hypothesis, null model or
uncertainty, so nothing here is a verdict. The harness, fixtures, and the
append-only `LOGBOOK.md` with every run are at tag
[`research/tool-compiler/000`](https://github.com/andreasronge/ptc_runner/tree/research/tool-compiler/000)
under `scripts/labs/tool-compiler/`. That tag includes the corrections from
#2015, #2016 and #2017.

## Question

Does compiling a domain tool from observed usage pay for itself, compared
with a model driving the raw upstream tools?

## Conditions

- A loopback fixture serves quotation records on three pages that differ in
  DOM shape. Each page has a decoy in the navigation, and one page hides three
  records behind forty filler rows.
- **Arm A:** the model drives `ptc-web@0.1.0`'s six page tools through a
  passthrough wrapper, with no domain knowledge.
- **Arm C:** a PTC workflow searches for a selector recipe through two probes,
  `read-text` and a batched `try-recipes`.
- **Arm B:** the recipe is stored as data in a manifest that installs no
  model, and the pages are extracted with it.

## Results

| stage | tool calls | model calls | input tokens | micro USD | correct |
| --- | ---: | ---: | ---: | ---: | --- |
| Arm A, one pass over 3 pages | 61 | 59 | 196,098 | 5,527 | 0/3 |
| Arm C, once | 101 | 11 | 52,859 | 2,615 | — |
| Arm B, one pass over 3 pages | 12 | 0 | 0 | 0 | 3/3 |

- **Arm A** was correct in 0 of 9 attempts over three runs. The runs failed by
  exhausting the turn limit or by returning the decoy and the filler rows.
- **Arm C** found `article` / `p` / `span`. This is broader than the
  hand-written `article.entry` / `p.words` / `span.speaker`, and more fragile
  on pages that put other prose inside an article.
- **Batching mattered.** Applying many candidates to one page snapshot took the
  search from 35 page loads for 30 candidates to 10 loads for 81 candidates.

## Limits on these numbers

- **Arm A was restricted.** The lab's wrapper hid `ptc-web`'s HTML source, the
  per-field options, and extraction pagination (#2015). The 0/9 result and
  Arm A's cost measure blind probing, not the upstream tool, and the corrected
  baseline was never run.
- **The acceptance check had seen its data.** The page used as the acceptance
  check was visible to the compiler during its search, so it served as
  validation data (#2017). The tagged harness adds an unseen `/acceptance`
  page that gates promotion, but no run since then has been repeated against
  it.
- **Cost totals.** Arm A's per-row spend is authoritative. The Arm B and Arm C
  totals are historical values reported at the time (#2016).
- **Scale.** 3/3 comes from one compilation on these fixtures. It does not
  show that compilation repays its cost in general.

## Runtime wants

- A command that lists an MCP installation's tools with their schemas.
  Discovering `ptc-web`'s tools meant reading its npm build.
- Documentation on raising `limits.run_duration_ms` and
  `limits.workflow_timeout_ms`, which are separate settings. Raising only the
  first led straight to the second limit error.
- `ptc transcript` requires the canonical `.ptcins` name and physically
  separate directories. It cannot certify a run whose trace dropped events,
  and here the dropped event was the one `limit-exceeded` event that explained
  the failure.
- `analysis/runs` reported 8 model calls for a run whose envelope and turns
  show 11.
