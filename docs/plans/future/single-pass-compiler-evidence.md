# Evidence: a single-pass incident compiler against the agent loop

**Status:** experiment record and handoff, 2026-08-02/03, branch
`worktree-incident-evidence-compiler`, extended 2026-08-04. One model, two
corpora, 101 recorded runs:

| set | corpus | runs | file |
| --- | --- | --- | --- |
| `fast` / `loop`, ten reps per cell | 3 incidents, 9-13 records | 60 | `paired-2026-08-03*.jsonl` |
| `authored`, three reps | same | 9 | `authored-2026-08-03.jsonl` |
| all three arms | `schema-migration-stall`, 332 records | 9 | `stress-2026-08-03.jsonl` — **superseded** |
| coverage-aware arms | same | 6 | `coverage-2026-08-04.jsonl` — **superseded** |
| all three arms, retrieval fixed | same | 17 | `stress-retrieval-fixed-2026-08-04.jsonl` |

Nothing here is a release claim; see *Limits* before quoting any number, and
*Conclusion* before quoting the comparison at all.

**Two of these sets measure nothing about the arms.** The 2026-08-03 stress
round and the 2026-08-04 coverage round both ran against an evidence server that
could not return one of the records the oracle requires — a transport encoding
defect that killed the run outright — on a corpus no arm drained. Both are kept
because the reasoning they record was sound and the mistake is instructive, but
every number in them is superseded by the final row.

The branch is rebased onto `origin/main` and has no PR open. The tagged-union
contract fix this branch once carried is no longer outstanding: `main` landed
its own, and this branch's version was dropped as superseded.

Context: [`incident-evidence-compiler.md`](incident-evidence-compiler.md) Phase 3
proposes a four-system comparison and requires bars committed in writing before
the full matrix runs. This is **not** that comparison. It is the dogfooding that
Phase 1 exists to produce — build the application, then discover what the
runtime cannot yet express — and it happens to have produced a result worth
recording before the pilot is designed.

## What was compared

Three ways of running the same application, on the same corpus, same model
(`openrouter:deepseek/deepseek-v3.2`), same result contract and citation check.
`fast` and `loop` were compared first; `authored` was added later.

| arm | shape |
| --- | --- |
| `loop` | `incident.compiler/run` — the shipped `agent.core` loop |
| `fast` | fetch everything in one program, one model call for the whole report, verify, plus one correction turn if citations fail |
| `authored` | as `fast`, except the model **writes** the gathering program: one call to author it, `check-source` to validate it, then the same single report call and verification |

The fast arm is a plain PTC-Lisp workflow, ~100 lines: one `kernel/eval-source`
that searches and fetches every record, one `llm/request` carrying all bodies
and the generated result-contract description, then `resolve-citations` over
every citation before returning. Retrieval is a **program**, not a sequence of
model turns.

## Result

Three incidents × two arms × ten reps = 60 runs, plus a third arm at three
reps added later — 69 runs in total.

| incident | arm | calls (median, range) | recall (median, range) | published |
| --- | --- | --- | --- | --- |
| checkout-5xx | fast | 1 (1-1) | 0.86 (0.29-1.00) | 10/10 |
| checkout-5xx | loop | 16 (10-20) | 0.57 (0.14-1.00) | 10/10 |
| dual-cause-payments | fast | 1 (1-1) | 0.86 (0.00-1.00) | 10/10 |
| dual-cause-payments | loop | 15.5 (8-21) | 0.57 (0.14-1.00) | 9/10 |
| batch-silent-failure | fast | 1 (1-1) | 0.80 (0.40-1.00) | 10/10 |
| batch-silent-failure | loop | 11 (7-17) | 0.60 (0.40-1.00) | 10/10 |

```
fast  calls median= 1  total= 30   recall median=0.86  range 0.00-1.00  published 30/30
loop  calls median=14  total=410   recall median=0.60  range 0.14-1.00  published 29/30
```

The recall difference survives a test that respects incident as a blocking
factor: shuffling arm labels within each incident (200,000 draws) puts the
observed block-averaged difference of +0.170 at p=0.017. No single incident
reaches significance alone (p=0.10, 0.07, 0.66) — the result rests on all three
blocks pointing the same way, not on any one of them. Publication rate does not
differ (30/30 against 29/30, Fisher p=1.0).

Every published report in both arms was fully grounded: zero unresolved and
zero mismatched citations, verified against the evidence source. As one fast
run shows below, that is a weaker property than it sounds.

### The authored arm

Added later, on the same corpus, after `main` landed `check-source` and
parameterized evaluation. Three incidents × three reps = 9 runs.

```
authored  calls median=2  total=18   recall median=0.86  range 0.71-0.86  published 9/9
```

Same median as `fast` (0.86) at one extra call, and **far more consistent**:
0.71–0.86 against `fast`'s 0.00–1.00. Because the earlier three-rep record was
wrong about exactly this — it read a narrow range at small n as stability — the
claim was checked rather than eyeballed. Resampling `fast` under the authored
arm's own design, three runs per incident, 200,000 draws:

| | |
| --- | --- |
| P(a `fast` sample being this tight) | **0.0002** |
| P(a `fast` sample's mean being this high) | 0.24 |

So the consistency is real and the central tendency is not. `authored` does not
compile *better* reports than `fast` on this corpus; it compiles reports whose
quality varies far less, and it never produced the fully-grounded-but-empty
report that `fast` did.

**It did not write the program that was predicted.** The expectation was that it
would re-derive "search once, fetch everything", pay one extra call, and tie.
Instead it enumerates `list-sources` and searches per source, and it returns
*fewer* records than `fast` does — median 12, range 9–13, against `fast`'s
flat 13. Fetching less and scoring the same median, with a fraction of the
spread, is not what a re-derivation looks like. Why a source-balanced traversal
would be steadier than a flat fetch is a hypothesis this corpus cannot settle.

**Authoring never failed.** 9/9 programs were runnable and `check-source`
rejected none, so the repair turn never fired — the same result as the fast
arm's correction turn, and it costs nothing when unused. That the repair path is
untested here is a gap, not a reassurance.

## The stress corpus, first round (superseded)

> **Read this section as a record of a measurement that was wrong, not as a
> result.** Two defects, both outside the arms, made this corpus unsolvable:
> one evidence record could not be fetched at all without killing the run, and
> no arm drained the search. Both are fixed. The round that measures the arms
> is *The stress corpus with retrieval fixed*, below. What survives from here
> is the corpus design and the reading discipline — the reports were hedged
> correctly and only reading them showed it.

`schema-migration-stall`, 332 records across 8 sources, generated by
`tools/gen_stress_corpus.exs` and built so that no arm can fetch it whole:
`search` caps at 50 and defaults a missing limit to 20, and the incident opens
with hours of routine traffic, so a truncated search returns only the
pre-incident tail. It is solvable two ways — per-source search at limit 50, or
a union of targeted queries — and reaches 0 of 7 needles by taking the earliest
records.

Three arms, three reps:

| arm | published | calls | required-fact recall |
| --- | --- | --- | --- |
| `fast` | 1/3 | 1, 1, 2 | **0.00** |
| `authored` | 0/3 | 2, 2, 3 | — |
| `loop` | 2/3 | 24, 29, 24 | **0.00, 0.00** |

**Every arm scored zero.** Not "worse" — zero. Three published reports between
them, all fully grounded, none containing a single required fact.

**But zero here does not mean what it meant on the small corpus, and reading
the reports is what shows it.** Every published report correctly characterised
the evidence it was given and named what it was missing:

> The provided evidence shows normal operations for orders-service and its
> database from 20:01 to 21:25, **with no indication of a schema migration
> stall** on the public.orders table.

Its open questions ask for migration entries touching `public.orders`, lock
samples showing waiters on it, and alerts indicating degradation — which are
precisely the records it never received. The model was handed 50 shift-handover
notes and objective checks and said so.

So `required_fact_recall` is measuring **retrieval** here, not reasoning, and
the metric cannot tell a well-hedged 0.00 from a fabricated one. On the
13-record corpus a 0.00 meant the model had the evidence and missed it; on this
one it means the evidence never arrived. Reporting both as "scored zero" without
that distinction was wrong, and only reading the reports caught it.

The prediction registered before the run holds exactly. The authored programs
fetched **160 records every time** — eight sources times the twenty-record
default — and 160 is not a number anyone chose; it is what ignoring `truncated`
costs on this corpus. The fast arm's single 50-record search returned the
earliest 50 of 332, all pre-incident. The loop spent 24–29 calls and cited five
records. None of the three ever learned it was working from a subset, because
none of them reads `truncated`.

**The comparison is uninformative here, and that is the finding.** These arms
differ in how they orchestrate a model; they share one retrieval assumption,
and the corpus breaks that assumption first. Whatever separates a single pass
from a loop is invisible behind a common failure that has nothing to do with
either. The earlier 69 runs measured three orchestration shapes on a corpus
where retrieval could not fail; this one shows what the shapes are worth when
it can.

**A second failure sits underneath.** `result_contract_failed` accounts for
five of the six non-publications, and at least one is not a reasoning failure:
one rejected report carried **20 citations on a single observed fact** against
a schema that allows 8. Given far more evidence than the contract was drawn
for, the model piles citations onto individual claims and breaches a bound the
13-record incidents never approached. That is a defect in the application's
contract, not in any arm.

**It was one instance then; it is a pattern now.** With retrieval fixed it
accounts for three of the four `authored` non-publications in the 2026-08-04
round. One rejected report again carried exactly **20 citations on a single
observed fact**; another resolved **160 distinct citations** — every one of
them real, zero unresolved, zero mismatched — and was still refused. The
contract's per-claim cap of 8 and its per-array caps were drawn against
13-record incidents, and a model handed 160–332 records saturates them. The
citation check and the contract now disagree about what a well-grounded report
looks like, and the contract is the one that is wrong. Still not changed here,
for the same reason as before: it is one line, and changing it mid-comparison
would confound the arms it is being measured against.

### What the model saw, and what it wrote

Read back through the inspection profile before touching anything, because the
obvious fix assumes the model lacked information.

**It did not.** The authoring prompt is 10,264 bytes of mission model context
and it names `limit`, `truncated` *and* `matched` — in every authored run. The
model was shown that `search` takes a `limit` and answers how many records
`matched` and whether the page was `truncated`, and used none of the three. The
fast arm's report prompt is 18,813 bytes; nothing here is a context-size
failure either.

The three programs it wrote are idiomatically varied — one `reduce`, one
`->>` with `#()` and `mapcat`, one using keyword access throughout — and
structurally identical: `list-sources`, then a per-source `search` with `nil`
in the limit position, then `get-record` per summary. All three ran, all three
passed `check-source` with no repair, and all three returned exactly 160
records.

So this is not a broken program and not a missing fact. Each program is correct
about what it does; none of them entertains the possibility that `search`
returned less than everything. Reading `records` without reading `matched` is
the whole failure, and the field was on screen.

That changes what the fix is. Passing `limit 50` repairs this corpus and
nothing else — the next corpus is 600 records and 50 is wrong again. What the
evidence argues for is either an authoring prompt that says something about
completeness rather than trusting the signature to imply it, or a tool that
makes truncation impossible to ignore: a cursor that must be drained, or a
refusal to answer a query whose result it had to cut. Documenting the field
demonstrably is not enough.

One thing `check-source` cannot do, worth knowing before leaning on it: it
resolves names, not shapes. Every one of these programs is name-correct and
semantically blind, and it passed all three.

**The 2026-08-04 round answered the "or" in that paragraph, and the answer is
both.** Told the shortfall and nothing else — *"a previous program returned 160
of the 332 evidence records this incident holds"* — the model reaches for the
cap and for the field it had been ignoring. Across the six repair programs this
round produced: **5 of 6 pass `limit 50`**, **4 of 6 read `truncated`**, and
**5 of 6 write a `loop`/`recur` drain**. So a prompt that mentions completeness
is enough to get the field read; trusting the signature to imply it was not.
But those drains are built around a **cursor that does not exist**:

```clj
(loop [acc [] offset 0]
  (let [search-result (incident.evidence/search incident-id nil source 50)
        …]
    (if (:truncated search-result)
      (recur new-acc (+ offset (count records)))   ; `offset` is never passed
      new-acc)))
```

`search` takes no offset, so `recur` re-issues the identical query. These
programs terminate only because no source in this corpus exceeds 50 and
`truncated` is therefore always false; on a corpus where one did, this is an
infinite loop bounded by the evaluation timeout. The model was not confused
about *whether* to drain — it was confused about *how*, because the tool offers
no way. That is the strongest argument yet for the guardrail in *Next step*:
the shape the model reaches for unprompted is a cursor, and the API should
either have one or refuse the query it had to cut.

### Telling the model its coverage changed nothing, because it already knew

The report prompt was made truthful — it had been asserting "Every record below
is the complete evidence" unconditionally, which was false the moment retrieval
fell short. With an accurate "these are 50 of the 332 records this incident
holds" the fast arm published 3/3 at 0.00, the same as before.

The reason is not that the model ignored the sentence. Reading the reports from
both conditions side by side, they are equally hedged: without the sentence it
already wrote "no indication of a schema migration stall", because fifty
consecutive shift-handover notes are self-evidently not an incident. The
coverage line told it something it had inferred from the data.

That does not make the line useless — a corpus whose first fifty records looked
alarming would not be self-evident — but it does mean this experiment failed to
test what it was built to test, and the earlier reading of it ("information is
not the binding constraint") was not supported by it.

One genuine finding survives. The prompt's only rule about missing evidence is
*"where the evidence does not answer a question that matters, record an open
question"* — which prescribes handling it **inside** a report. The
`insufficient_evidence` branch appears solely as an unexplained line of schema
in the contract dump. A model told it is missing evidence, and told what to do
when evidence is missing, does the thing it was told. If abstention is wanted,
the rules have to say so.

Not fixed here, deliberately. The obvious repairs — pass `limit 50`, read
`truncated`, raise the citation cap — are each one line, and applying them
before the failure is recorded would turn a measured result into an anecdote
about a corpus that was quietly adjusted until the arms passed.

### The undiagnosed failure was one record, not call 251

The open item this round inherited was: *the authored arm's programs fetch past
250 records and the 251st call errors — not a limit (4096 ceiling, no protocol
errors, 596s remaining)*. The count was a coincidence. Every failure in every
recorded stress run — both coverage-aware authored runs and the loop arm's one
non-publication — is the same call:

```
evidence.get chat-7810 -> provider_error/invalid_result (mcp_protocol_error)
```

`chat-7810` is the **only record in the entire eleven-incident fixture set that
carries a character outside ASCII** — an em dash in *"No change in behaviour —
the queue had already drained by then."* The runtime grants a stdio child a
fixed compatibility environment with no `LANG`, Erlang's `:stdio` therefore sits
in latin1 mode, and `IO.write/2` emitted the literal text `\x{2014}` instead of
the character's UTF-8 bytes. That is not valid JSON, the client refuses the
frame, and a stdio transport failure is terminal — so one record ended the run.

It reproduces in seconds with no model in the loop, and the boundary is exactly
the locale:

```
$ echo "$get_chat_7810" | elixir server/evidence_server.exs …      # LANG set
b'behaviour \xe2\x80\x94 the qu'
$ echo "$get_chat_7810" | env -i PATH=$PATH elixir …               # no LANG
b'behaviour \\x{2014} t'
```

**This made the corpus unsolvable, not merely hard.** `chat-7810` is one of the
two records the oracle requires as contradicting evidence for
`release-caused-it`. No arm could reach it, and any arm that tried to retrieve
the corpus whole died. The first round's scores were not measuring retrieval
strategy; they were measuring which arms happened to stop before reaching one
record. Fixed in the fixture server with `IO.binwrite`/`IO.binread`, and pinned
by a test that fetches that record through the real transport and compares its
body byte-for-byte with the corpus file.

The general lesson is worth more than the fix: **a corpus of hand-written
English is almost all ASCII, so an encoding fault in the transport hides until
exactly one record trips it** — and then presents as a reasoning failure with a
plausible-looking score.

## The stress corpus with retrieval fixed

2026-08-04. Everything in *Next step* items 1–3 of the previous record is in
place, and the transport defect above is fixed, so this is the first round in
which the stress corpus measures the arms.

What changed in each arm, and it is deliberately not the same change, because
the arms differ in *who writes the retrieval*:

| arm | change |
| --- | --- |
| `fast` | its hand-written program enumerates sources, drains each at `limit 50`, unions by `evidence_id`, and reports what it holds against `matched` and the source's own `record_count` |
| `authored` | unchanged in how it retrieves — the model still writes that program. The arm's coverage check now takes `matched` as well as `record_count`, and one re-authoring turn is given the shortfall and nothing else |
| `loop` | one paragraph of task text: a search returns a page, it reports `matched` and `truncated`, and a report compiled from a subset is wrong even when every citation resolves |

Both single-pass prompts gained one rule — that abstention is an outcome — and
both arms now accept an `insufficient_evidence` terminal instead of running it
through citation resolution, where it fails as uncited. The loop already did.

**Limits are pinned and the pinning is verified, not asserted.** Partway through
this round the loop exhausted `normal_event_bytes` (see *Runtime friction
found*), so it was raised in all three manifests and every arm re-run under the
new one. Neither event-budget field appears in `limit_projection`, and the
evidence for that is direct: across the change the authored arm's authoring
prompt is byte-identical at **10,264 bytes**, same SHA-256, and the fast arm's
report prompt is byte-identical at **117,114 bytes**. Rows from before and after
are therefore one condition and are pooled. The loop's earlier rows are not
pooled — that arm failed *on* the budget, so for it the two settings are
genuinely different conditions.

### Result

`schema-migration-stall`, 332 records, of which the oracle names **9** as the
evidence its requirements rest on. Two coverages, both derived the same way for
every arm from its private inspection record rather than from an annotation only
two arms emit: `read_coverage` over the whole corpus, and `oracle_coverage` over
those 9. Recall is over published reports only; an abstention has no observed
facts and is counted separately.

| arm | n | **reports** | abstained | failed | read coverage | **oracle coverage** | calls | required-fact recall |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `fast` | 6 | **6/6** | 0 | 0 | 1.00 | **9/9 in 6/6** | 1 | **0.86** (0.71–0.86) |
| `authored` | 8 | 3/8 | 1 | 4 | 0.48 (0.48–1.00) | 9/9 in 3/8 | 3 | 0.71 |
| `loop` | 3 | 1/3 | 1 | 1 | 0.48 (0.00–0.96) | **0/9 in 3/3** | 35 (26–39) | 0.00 |

The first column counts **delivered reports**, not successful runs. An
abstention exits zero and satisfies the contract, so counting it as a
publication would credit a withheld report as a delivered one; the row carries
both `published` (the run returned a contract-valid terminal) and
`report_published` (that terminal was a report), and only the second belongs in
a quality comparison.

**The corpus is solvable and the single pass solves it, every time, on one model
call.** Six of six runs retrieved all 332 records and published a grounded
report at a median 0.86 required-fact recall — against 0.00 for every arm in the
first round. The separation is not marginal and no significance test is offered
for it: it is categorical, and the category is *did the arm reach the evidence*.

**Oracle coverage is bimodal, and it predicts publication exactly.** Every run
scores 9/9 or 0/9, nothing between: the nine records sit at positions 25–43
within their sources and the search defaults a missing limit to 20, so an arm
that passes a limit drains everything and an arm that does not sees none of it.
There is no partial credit to earn.

The correspondence with the outcome is total. **All nine runs that reached 9/9
delivered a report; all eight that reached 0/9 failed, abstained, or published
the empty-negative report described below.** No run reached the evidence and
then failed, and none published a real report without it. `read_coverage` tracks
none of this — the loop's 0.96 run is in the 0/9 group.

**The one fact every successful run misses is the same one.**
`scaling-no-effect` — that the pool was scaled 40→120 with no effect — is absent
from the observed facts of every published report in every arm. Most cite its
record (`chat-7788`) under a *hypothesis* instead, which the oracle does not
credit. That single requirement is the whole distance between 0.86 and 1.00.

**Retrieval being fixed did not make the arms equal; it moved each one's failure
somewhere new.** Every remaining failure in this round is at a boundary rather
than in the reasoning:

- `fast` has none. Its retrieval is a program a human wrote against the API's
  documented behaviour, and it is the only arm that never needed to discover
  the cap.
- `authored` fails on **shape**, three ways, none of which `check-source` can
  see: a program returning a vector-of-vectors, so the arm counted 8 "records"
  while the trace shows all 332 fetched; a `(filterv :found …)` applied *after*
  unwrapping to the inner record map, where `found` no longer exists, yielding
  zero; and reports that saturate the result contract's citation caps. Its
  repair turn is also not monotonic — in one run the rewrite returned *fewer*
  records than the program it replaced, and the arm kept the better of the two
  only because it explicitly compares.
- `loop` fails on **feedback**. It read `matched: 332` — the instruction
  landed — concluded it needed a bigger page, and asked for `limit 100`. The
  installed tool's schema caps `limit` at 50, the dispatcher refuses with
  `kind=:protocol_error; reason=:invalid_arguments`, and neither the argument
  nor the bound is named. The `:signature` the model sees says `limit :int?`
  and states no maximum, so there is nothing to learn from. It sent the
  identical call **18 times** until `protocol_errors` aborted the run.

### The loop guessed the identifiers, and the coverage metric believed it

This is the result worth carrying forward, and it was misread here first.

The loop's third run reached **96% read coverage — 320 of 332 records — while
holding 0 of the 9 records the oracle names.** The obvious reading, that it had
the evidence and failed to reason over it, is wrong. What it did was this:

```clj
(defn generate-correct-ids-for-source [source-name record-count]
  (let [prefix (get source-prefixes source-name)]
    (mapv #(str prefix "-" (format "%04d" %)) (range 1001 (+ 1001 record-count)))))
```

Unable to page past the cap, it inferred the identifier scheme from its first
page — `mig-1001`, `lock-1001`, … — built a prefix map for all eight sources,
and enumerated `prefix-1001` upward by each source's own `record_count`. That
produced exactly 332 identifiers, of which 320 exist. **Every guess that
resolved was filler; every record that mattered has an identifier off the
pattern** — `mig-4410`, `lock-9001`, `lock-9044`, `lock-9102`, `chat-7788`,
`chat-7810`, `dep-5501`, `pool-3310`, `run-2205`.

It then published, grounded, with all thirteen citations resolving:

> All migration statements were applied to tables other than public.orders
> — cited to `mig-1001`, `mig-1002`
>
> No lock waits were recorded on public.orders table during the migration period
> — cited to `lock-1001`, `lock-1002`

Universal negatives inferred from two filler records each, in a corpus that
contains the contradicting evidence. Its summary states the incident did not
happen: *"No evidence shows locks on the orders table or a stalled migration,
contradicting the incident title."*

Three things follow, and none of them is about this arm.

**A count-based coverage metric can be satisfied by fabrication.**
`read_coverage` was added this round to stop a retrieval failure from reading as
a reasoning failure, and 0.96 would have done exactly the opposite — it would
have certified this run as one that had the evidence. Coverage against the
records the oracle requires cannot be gamed the same way: those identifiers are
not derivable from the data, only from having retrieved them. Both are reported,
and `oracle_coverage` is the one to read first.

**The citation check does not catch it.** Thirteen citations, zero unresolved,
zero mismatched, every digest matching the stored record. Grounding constrains
what a claim may cite; it says nothing about what the claim omits, and a
universal negative is precisely the claim shape that a subset can never
support. The earlier record found a fully grounded report that was *empty*;
this one is fully grounded and **wrong**.

**And a guessable identifier scheme is a corpus defect worth fixing.**
`tools/gen_stress_corpus.exs` numbers filler sequentially from 1001 per source,
which is what made enumeration pay. The needles being off-pattern is what made
the failure legible here, but a corpus whose ids can be derived from a source
listing lets an arm skip retrieval altogether. Not changed in this round — it
would have invalidated the comparison mid-flight — and it is now the first item
under *Open items and traps*.

### The abstention rule fires, in two arms, for the right reason

Item 3 of the previous record asked for one line and named its own test: *does
coverage short of total produce the abstention branch?* It does, and not only in
the arm it was written for.

`authored`, at 160 of 332 records:

> …no recorded lock waits or performance issues. There is no indication of a
> stall in the provided records, **which are incomplete (160 out of 332 total
> records)**, making it insufficient to determine the cause or nature of the
> incident.

`loop`, independently, from a different subset:

> Available evidence does not cover the incident period… **Evidence stops at
> 2026-07-19T00:27:00Z while incident was opened at 2026-07-19T03:05:00Z**,
> leaving a critical gap.

Both withheld rather than assembling a report out of routine traffic, and both
named the gap precisely. Neither would have been possible before: an abstention
carries no citations, so the single-pass arms used to route it into citation
resolution, fail it as uncited, and spend a correction turn demanding citations
the shape forbids.

The rows now carry `abstained: true` beside `required_fact_recall: 0.0`, so
those two zeros are legible as what they are. What the scorer still cannot say
is whether each abstention was *right*: `abstention_defensible` is a property of
the incident — and this incident does support a report when fully retrieved — not
of the coverage the run happened to have.

## What was unexpected

**The correction turn never fired.** `corrected: 0` in all thirty fast runs. It
was added because the loop's one structural advantage is a correction turn, and
it turned out to be unnecessary on this corpus. It costs nothing when unused.

**A fully grounded report can still be worthless.**
`fast-dual-cause-payments-4` published twenty-one citations, ten of them
checked, zero unresolved and zero mismatched — and scored 0.00 required-fact
recall. Every claim it made was traceable to a real record with a matching
digest; it simply made none of the claims that mattered. The citation check
verifies grounding, not relevance, and nothing at three reps had exercised the
gap. This is the most useful thing the extra reps bought.

**At three reps the single pass looked tighter. It is not.** The earlier record
said it never scored above 0.86 or below 0.29 and read that stability as
evidence the single pass was the safer shape. At ten reps both arms span nearly
the whole range — fast 0.00-1.00, loop 0.14-1.00. The medians separate; the
distributions overlap heavily. What survives is that the fast arm's median is
higher at a fourteenth of the calls, not that it is steadier.

**The fabrication reading did not survive either.** The loop still owns the only
failure — `dual-cause-payments` rep 2, failed closed with
`unresolved-citations` after 17 calls — but one failure in thirty against zero
in thirty is no evidence at all (Fisher p=1.0). That more turns mean more
chances to invent a citation remains a plausible hypothesis with nothing behind
it. Testing it needs a corpus where either arm fails often enough to count.

## What was tried and did not pay off

**Triage** (`fit/handles?`): one cheap model call reading the target export's
own documentation through `export-meta` plus a `describe` projection of the
data, answering whether a single pass suits this task. The mechanism works —
against synthetic inputs it correctly rejects a 4,200-record corpus with
`scale`/`iteration` and a heavily cross-referenced one with `iteration`, citing
the disqualifiers the docstring names. Against the real corpus it answers yes
12/12, which appears **correct**: every incident is 11-13 records, ~2.3 KB, six
sources. There is no hard case in the fixtures for it to reject, so triage adds
a call and no information here.

Three rounds of apparent triage failure all turned out to be defects in what it
was fed, not in the judge:

- the target's docstring described mechanics and never claimed the report
  separates facts from hypotheses, so the model would not assert it did;
- `json/generate-string` returns `nil` for an atom-keyed map, so
  `(json/generate-string (describe records))` sent an **empty** data shape in
  every call — the model's repeated "no input data shape is provided" was a
  true statement about its input, read for several rounds as confabulation;
- the sample was labelled "the data it would receive" when the signature takes
  an incident id and fetches internally.

Filed as [#1165](https://github.com/andreasronge/ptc_runner/issues/1165).

## What the private logs show

Analyzed with the runtime's own `inspection-analysis-v2` profile rather than by
reading JSONL from outside, so the numbers come from the same correlated
private records an operator would query.

**Every run fetches each record twice, and it is correct.** Across all 9
authored runs, `evidence.get` calls run 45–50% duplicate — 26 calls for 13
records. The first hypothesis, that the model's per-source traversal was
silently dropping records to paging, is **wrong**: `matched` equals `returned`
in every search and no `truncated` flag is ever set. Attributing the calls by
`evaluation_id` gives the real answer:

```
mission-evaluation-10  gets 13  distinct 13   <- the gathering program
mission-evaluation-36  gets 13  distinct 13   <- the citation verification
```

One gather pass, one verify pass, no duplicate inside either.
`resolve-citations` re-reads each cited record from the evidence source instead
of trusting the copy the program already holds, which is what makes it a check
rather than a restatement — verifying against the same bytes the model was
shown would be circular.

The control matters here: **the fast arm shows the identical ratio in all 20 of
its runs**, so this is a property of the application's verification step, not of
model-authored retrieval.

**What the model actually wrote, and what it said.** Reading the generated
sources and the model's own replies back out of the same records:

| | |
| --- | --- |
| distinct programs across 9 runs | **8** |
| replies carrying prose | **0** |
| report replies wrapped in a ```` ```json ```` fence, against an explicit instruction not to | **7 of 9** |
| programs reading `data/params` | 0 |
| programs hardcoding the incident id as a literal | 9 |
| programs that read `truncated` | 0 |

Eight distinct programs in nine runs, at `temperature 0` with a fixed seed:
temperature zero is not determinism. No reply ever carried narration — the
authoring prompt asked for program text and nothing else, and got exactly that
nine times out of nine. The *report* call is the one it disobeys, fencing its
JSON in seven of nine replies despite being told not to; `parse-report` strips
fences, so this costs nothing and would have been invisible without reading the
exchanges.

Two things follow for work already planned. Every program bakes its incident id
in as a literal, so **as authored these are single-use artifacts** — promoting
one into a reusable component (#1167) needs a parameterization step, and the
authoring prompt never mentions `data/params`, so that is a prompt gap rather
than a model failure. And **no program reads `truncated`**, which cost nothing
here because nothing ever truncated, but is precisely the silent-evidence-loss
failure the hard case would trigger.

**The consequence is a scaling ceiling nobody had costed.** Mission capability
calls follow `2R + S + 1` exactly — twice the record count, one search per
source, one `list-sources` — while `llm_calls`, the headline metric of this
whole comparison, hides it completely. Measured against every incident in the
corpus, and `checkout-5xx` matches at 2×13+6+1 = 33.

The manifests capped `mission_capability_calls` at 512, reached near 250
records. **Raised to 4096** (host ceiling 8192), sized from the rule above, in
preference to weakening verification: re-reading each cited record is what makes
the check a check, and sampling would trade an integrity property for headroom.

**A second, harder ceiling sits underneath it.** The evidence server caps
`search` at `@max_limit 50` and defaults a missing limit to 20, and it returns
no cursor. The fast arm asks for 50 and ignores `truncated`; the authored
programs pass `nil` and take 20 per source. So no arm can see more than 50
records from one call, and beyond that the corpus is reachable only by issuing
*more* searches — per source, or by query. Raising the call limit does not
touch this.

That is left as it is. A capped, filterable search is what an evidence API
actually looks like, and changing the system under test to make the experiment
work would answer a question nobody asked. It does mean the hard case is not
"can an arm afford hundreds of records" but **"can an arm reach evidence it
cannot fetch wholesale"** — which is the assumption the fast arm has never had
stressed, and the one a generated program is supposed to be better at.

Registered before the run, so it can be wrong: on a corpus of several hundred
records the fast arm should degrade badly, because one 50-record search cannot
see the evidence; the authored arm should do better only if it searches per
source *and* passes a limit, which none of the nine programs it has written so
far does; and no arm reads `truncated`, so all of them will lose evidence
silently rather than fail.

## Runtime friction found

Four of these were found by the 2026-08-04 round; three are now filed. Each of
them silently corrupted a measurement before it was understood.

- [#1177](https://github.com/andreasronge/ptc_runner/issues/1177) — **a stdio
  MCP child gets no locale, and an Elixir server in character mode then emits
  invalid JSON.** `HostInstallation` grants a stdio child a fixed
  compatibility environment — `HOME LOGNAME PATH SHELL TERM USER` — with no
  `LANG` or `LC_*`. Erlang therefore puts `:stdio` in latin1 mode, and
  `IO.write/2` renders any codepoint above 127 as the literal escape
  `\x{2014}`. That is not valid JSON, so the client answers
  `mcp_protocol_error`, and because a stdio transport failure is terminal the
  whole session dies on one record. The server is at fault and is fixed here
  (`IO.binwrite`/`IO.binread`), but the trap is general: any stdio server that
  trusts its locale to select UTF-8 — which is the default for Python and
  Elixir alike — breaks the same way, and only on the records that happen to
  carry non-ASCII text. Worth considering whether the runtime should grant
  `LC_ALL=C.UTF-8`, or say in the launch contract that it does not.
- [#1178](https://github.com/andreasronge/ptc_runner/issues/1178) — **exceeding
  the trace event budget fails a run that succeeded.** With
  `--inspect`, `InspectionArtifact.validate_correlations/2` resolves every
  inspection record against the trace's `capability-started` events. When the
  event sink drops events — `normal_event_bytes` defaults to **4 MB** and no
  manifest here set it — the correlation no longer resolves and `ptc.run`
  fails with `inspection_persistence_failed/inspection_correlation_missing`.
  The loop arm's workflow had already returned `ok` with a real `result_hash`;
  the run was still recorded as a failure. Nothing in the error names the
  budget or the drop, and the trace's own `events_dropped` counter — which
  does — is inside the artifact the failure discards.
- [#1176](https://github.com/andreasronge/ptc_runner/issues/1176) — **a rejected
  capability argument does not say which argument, or why.** The
  loop arm called `(incident.evidence/search … nil nil 100)`; the installed
  tool's `inputSchema` caps `limit` at 50, so the dispatcher refused with
  `kind=:protocol_error; reason=:invalid_arguments`. The model has no way to
  learn the bound — the `:signature` says `limit :int?` and states no maximum —
  so it sent the identical call **18 times** until `protocol_errors` (default
  32) aborted the run. Both the argument name and its bound are in the
  operator's own declared schema, so naming them satisfies the same verbatim
  rule that makes `invalid_arity` the next allowlist entry.
- **The replay recorder merges and never prunes.** A prompt change re-keys
  every fixture entry, and `record.exs` adds the new ones while leaving the old
  ones in place. `HEAD` carried 27 entries for 13 authored turns — 14 of them
  unreachable, accumulated across earlier prompt revisions. A clean rebuild
  (delete, re-record) is 13 and passes the same tests. Nothing checks that a
  fixture contains no dead entries.
- [#1165](https://github.com/andreasronge/ptc_runner/issues/1165) —
  `json/generate-string` returns `nil` silently for atom-keyed maps.
- [#1166](https://github.com/andreasronge/ptc_runner/issues/1166) — rejections
  that discard what the runtime knows: `split` on a string separator, `parse`
  unusable as a name because it is in `java_member_atoms`, `--inspect` path
  convention unstated, `--load` silently dropping a `return`.
- Fixed on this branch: declared annotation counter names containing a hyphen
  could never match, because the tool boundary rewrites hyphens to underscores
  while the declaration grammar requires kebab-case.
- [#1172](https://github.com/andreasronge/ptc_runner/issues/1172) — hit while
  analyzing this experiment's own private records. A private session answers
  `unbound_var` with only `private evaluation failed`, while the identical
  fault outside one says `Undefined variables: defn-, g, x`; the redacted names
  are the analyst's own script text, not captured data. Alongside it, `defn-`
  in dynamic source fails as an undefined *variable* rather than saying it is
  component-only, and a profile resource directory whose artifacts sit one
  level down answers `{"items" []}` — a capture that matched nothing reads
  exactly like one holding no runs.

## Runtime capabilities confirmed

Probed directly against the mission environment, no model calls involved,
because the answers decide whether a model-authored retrieval arm is buildable
at all. Every item here was re-verified after this branch rebased onto `main`
at [PR #1169](https://github.com/andreasronge/ptc_runner/pull/1169), which
changed the generated-program boundary; all of them still hold.

- Source handed to `kernel/eval-source` may contain `def` and `defn`, and what
  it defines **persists into later `eval-source` calls for the life of the
  run**. A function defined in one evaluation is callable from the next.
- A dynamically defined function may call mission capabilities — one defined in
  a probe called `incident.evidence/search` and returned its thirteen records.
- It may **not** shadow a protected namespace's public exports. Both `defn` and
  `def` against `incident.evidence/resolve-citations` are refused with
  `invalid_form: … it is a public export of the protected namespace …`, and the
  real function still answers afterwards. Model-authored code cannot rewrite
  the citation check that judges it.
- The generator and the generated code are necessarily on opposite sides.
  `llm`, `kernel-eval` and `kernel-mission-inventory` are workflow-side only
  (`runner.ex` `workflow_tools`, reserved in `environment.ex`), while
  `mission_tools` (`evaluation.ex`) grants only the mission environment's own
  capability callbacks. Generated code therefore cannot call the model or
  recursively evaluate, and is bounded by `mission_capability_calls`.

Two things `main` added while this branch was away change how generated code
should be written, and both were confirmed by the same probe:

- **`kernel/check-source` validates without executing.** It answers
  `{:outcome :valid, :source_hash …}` or `{:outcome :invalid, :diagnostic …}`,
  and it resolves names against the live mission environment — an undefined
  function is caught as `:unbound_var` before anything runs, where
  `(program …)` still surfaces the same fault only at evaluation. A repair loop
  no longer has to spend an evaluation to learn its program does not compile.
- **`kernel/eval-source-with` passes data as data.** Parameters arrive at
  `data/params` inside the evaluated program, so a value never has to be
  rendered into source text. A hostile string passed as a parameter comes back
  as a string, intact and never parsed — the injection shape that string
  concatenation creates is structurally absent rather than escaped around.

The components under `experiments/` still build their programs by
concatenation and predate this surface. That is now the wrong way to write
them; see *Next step*.

What this does *not* provide is a prelude in the bundle sense. A runtime `defn`
is not in the `FrozenBundle`: not covered by the component source hash, not
versioned, dead at end of run, and absent from `mission_inventory` — which is
built once at run construction, so **the model never sees its own library in
its tool context**, and with no declared `:signature` there is no `export-meta`
for `fit/handles?` to read. A generated library that should outlive its run has
to be promoted into a real component with a docstring and signature.

### What an independent review caught in the harness

Run against the four commits, `codex review` returned four [P2] findings, all in
`collect.exs` and all real. They are recorded because three of them are the same
species of defect this round exists to study — a measurement that reads as a
result.

- **`published` counted abstentions as delivered reports.** It derives from exit
  status, and an abstention exits zero. The table above originally read 4/8 and
  2/3 where the truth is 3/8 and 1/3. Fixed by deriving `report_published`
  separately; every number in this document is the corrected one.
- **Verifier fetches counted as model reads.** `resolve-citations` re-reads
  every cited record, and a record cited from a *search summary* — which carries
  `content_digest`, so citing without fetching is possible — would then be
  credited to the model. The artifact records each evaluation's source against
  its `evaluation_id`, so verification evaluations are now excluded exactly.
  **This changed no number here**: in every run that reached verification, the
  verifier's fetches were a subset of what had already been gathered.
- **`oracle_coverage` omitted the evidence behind required open questions.** An
  arm that never retrieved those records cannot raise the gaps the oracle
  requires. It happens not to matter for `schema-migration-stall`, whose one
  such record is already a required-fact record, but on `queue-backlog` it would
  have let coverage read 1.00 with all three gap records missed.
- **Absent metrics serialized as the string `"nil"`, not JSON `null`.**
  `:json.encode/1` special-cases only `true`, `false` and `null`; every other
  atom becomes a string. So the nil-not-zero distinction added earlier in this
  round survived the collector and died at the encoder.

The first and last had already reached this document as numbers. That is the
argument for pointing the review at the harness and not only at the runtime:
the code that computes a result is as able to be wrong as the code under test,
and it is not covered by the application's own tests.

A second, adversarial pass — `codex exec` prompted at the measurement rather
than at the code — returned ten more, three of them [P1]. Bare review-mode is a
weak gate; the prompted pass is what found the one that mattered:

- **[P1] Coverage credited records the model was never given.** The authored arm
  may run a second gathering program and discard it: `fetch-records` keeps
  whichever returned *more* records. On one run the retry fetched all 332 and
  returned them as eight nested vectors, so `(count …)` saw 8, the arm kept the
  first program's 160, and the prompt went out holding **none** of the nine
  oracle records — while the collector, unioning every evaluation's fetches,
  scored that run **9/9**. Corrected by selecting the evaluation whose distinct
  fetches match the count the arm itself reports, with `coverage_basis` on every
  row recording which rule applied. **Authored oracle coverage was 5/8 under the
  union and is 3/8 under the fix.** This is the third time in this round that a
  coverage number credited evidence a model never saw.
- **[P1] `prompt_coverage` is a count of an outer collection and validates
  nothing.** `run-program` accepts any non-empty sequential value. The same
  record 332 times, 332 search summaries, or 332 nils all report complete. Not
  fixed — see *Open items and traps*; the fix is a shape check in the arm, and
  changing an arm now would desynchronise it from the rows it produced.
- **[P1] Neither arm checks that the report is about the incident it asked
  for.** Abstention is recognised from `status` alone and the schema only
  requires `incident_id` to be a non-empty string, so a contract-valid report
  naming another incident exits zero and is scored against the requested
  incident's oracle. No run tripped this; it is a fail-open, not an observed
  fault.
- **[P2] `read_coverage` was not scoped to the incident under test** — any
  fetched id counted against this corpus's size, so records from another
  incident could push it to or past 1.00. Now intersected with the corpus.
- **[P2] The verifier exclusion is a substring match**, which over-matches an
  authored program that merely mentions the resolver. Narrowed to the
  namespaced `incident.evidence/resolve-citations`, and largely superseded by
  selecting the gathering evaluation directly.
- **[P2] The collector never checked that its five inputs describe one run.**
  Trace, inspection artifact, report, status and incident all arrive as argv.
  Now cross-checked on `run_id` and the report's own `incident_id`, surfaced as
  `artifacts_agree` — true on all 17 rows.
- **[P2] The fast arm does not drain a source holding more than 50 records**, and
  no fixture has one: the largest source in the corpus is 43. Its drain is
  therefore *correct here and untested beyond the cap*; it degrades honestly
  (`short_partitions` and an incomplete coverage sentence) rather than silently,
  but that path has never run.
- **[P2] The authored arm's `short_partitions` measures the diagnostic query,
  not the model's retrieval.** The coverage check always searches at limit 50,
  so the field reports corpus topology; a program making eight limit-20
  truncated searches still reports zero. Left as is and recorded, because it is
  the arm's own instrument rather than a result.
- **[P3] The fixture server treated a stdin read error as a clean EOF**, exiting
  0 on a broken transport. Fixed.

A third pass over the corrected collector returned one more [P1], also correct:
selecting *every* evaluation whose fetch count matches the arm's reported
`gathered` and unioning them re-introduces the same over-credit for the case
where two attempts fetch the same number of *different* records. `fetch-records`
replaces its result only on a strictly larger count, so an equal-sized retry is
discarded and the first attempt is what reaches the prompt; the collector now
takes the first match rather than the union. Two runs here do tie at 160, and in
both the attempts fetched identical records — so the fix changes no number and
is purely preventive.

## Limits

- **n=10 per cell**, 60 runs. The recall difference is significant under a
  blocked permutation test (p=0.017) and the direction is consistent across all
  three incidents. The distributions still overlap heavily, the effect leans on
  three same-direction blocks rather than any single one, and one model on one
  corpus cannot generalise regardless of p.
- **One model.** `deepseek-v3.2`. An earlier single-incident probe with
  `claude-haiku-4.5` moved recall but not turn count.
- **One corpus, no hard case.** Every incident is small and structurally
  similar. The fast arm's assumptions are never stressed, which is exactly why
  triage cannot be validated here.
- **Recall is mechanical.** Whether a cited record semantically supports its
  claim is not decidable this way; the oracle's `rubric` exists for a blind
  human pass that has not been run.
- **The 13-record medians describe a prompt that no longer exists.** The
  abstention rule was added to both single-pass prompts and to the loop's task
  text after those 69 runs. Nothing about retrieval changed for a 13-record
  incident — the drain returns the identical records — but the report call's
  rules did, so the tables above and the 2026-08-04 round are not poolable.
  Re-baselining the small corpus was not done; the instruction not to add reps
  there was followed.
- **The stress round is small per arm and its arms are not equally sampled.**
  Six `fast`, eight `authored`, three `loop`. No significance test is offered
  for it and none should be quoted; the separations that matter there are
  categorical — did the arm retrieve the corpus at all — not marginal.
- **`abstention_defensible` is a property of the corpus, not of the run.** The
  scorer marks an incident as one where withholding is defensible. It cannot
  say "defensible given what *this* run retrieved", which is the question two
  of the abstentions below actually raise.

## How to continue

Everything needed is committed under `incident_compiler/`:

| Path | What |
| --- | --- |
| `experiments/run.sh` | one cell per invocation; appends one JSONL row |
| `experiments/collect.exs` | joins trace annotations, usage, and the scorer into that row |
| `experiments/components/single-pass.clj` | the `fast` arm |
| `experiments/components/authored-pass.clj` | the `authored` arm |
| `experiments/components/fit.clj` | model-judged applicability via `export-meta` + `describe` |
| `experiments/components/documented-target.clj` | the documented export `fit` judges |
| `experiments/components/fit-stress.clj` | synthetic cases proving `fit` discriminates |
| `exp-single-pass.json`, `exp-loop.json`, `exp-authored.json` | the arms' manifests |
| `experiments/results/paired-2026-08-03.jsonl` | the first 18 rows (reps 1-3) |
| `experiments/results/paired-2026-08-03-reps-4-10.jsonl` | the further 42 rows (reps 4-10) |
| `experiments/results/authored-2026-08-03.jsonl` | the 9 authored-arm rows |
| `experiments/results/stress-2026-08-03.jsonl` | the 9 stress-corpus rows, superseded |
| `experiments/results/coverage-2026-08-04.jsonl` | the 6 coverage-aware rows, superseded |
| `experiments/results/stress-retrieval-fixed-2026-08-04.jsonl` | the round that measures the arms; each row carries its `set` |
| `tools/gen_stress_corpus.exs` | regenerates `schema-migration-stall` |

`collect.exs` takes the inspection artifact as a ninth argument, so
`read_coverage` is derived the same way for every arm rather than from an
annotation only two of them emit. It is `null`, never `0`, when the artifact is
missing — a run that could not persist its capture read an unknown number of
records, and calling that zero is the same conflation the metric exists to
prevent.

Add repeats:

```bash
export OPENROUTER_API_KEY=...            # or source .env, which lives in the
                                         # main clone, not in this worktree
./incident_compiler/experiments/run.sh checkout-5xx fast 11
./incident_compiler/experiments/run.sh checkout-5xx loop 11
./incident_compiler/experiments/run.sh checkout-5xx authored 4
```

The two arms use different manifests, so a `fast` and a `loop` stream can run
concurrently; two runs of the *same* arm cannot, because `run.sh` rewrites that
manifest's `incident_id` in place. Give each stream its own `PTC_EXP_DIR` so the
two appends to `results.jsonl` cannot interleave. A loop run is roughly 150s
against the fast arm's 70s, so a full sweep is paced by the loop arm.

Rows land in `incident_compiler/experiments/runs/results.jsonl` (override with
`PTC_EXP_DIR`); traces and inspection artifacts land beside them. Nothing is
overwritten — a new rep number is a new row. To extend the recorded set, append
those rows to `experiments/results/paired-2026-08-03.jsonl` or add a dated file
next to it.

`run.sh` clears its own per-tag artifacts first, because `ptc.run` refuses to
overwrite a result. That refusal caught a real harness bug: a failed run was
being scored against the previous run's report, which would have quietly
poisoned the whole results file.

**Layout constraint worth knowing.** The manifest loader rejects path
traversal, so a manifest cannot reference a component outside its own
directory. That is why the two manifests sit in `incident_compiler/` and point
*down* into `experiments/components/`, rather than living beside the components
they select. Moving them produces `:invalid_component`.

## Conclusion

**On a corpus where retrieval cannot fail, the single pass wins, and
model-authored retrieval holds up.** At ten reps per cell, `fast` reaches a
0.86 median required-fact recall at one model call against `loop`'s 0.60 at
fourteen, and the difference survives a permutation test that respects incident
as a blocking factor (p=0.017). `authored` matches `fast`'s median at one extra
call with a far tighter spread — 0.71-0.86 against 0.00-1.00 — and that
consistency, unlike the median, holds up when tested against a resample of
`fast` under the authored arm's own design (p=0.0002 for the spread, p=0.24 for
the mean).

**On a corpus where retrieval *can* fail, the separation is categorical and it
is about retrieval, not orchestration.** With the transport defect fixed and
every arm told to read `matched`, `fast` reaches all nine oracle records in 6 of
6 runs and publishes a grounded report every time on one model call. `authored`
reaches them in **3 of 8** and delivers exactly those 3 as reports. `loop`
reaches them in **0 of 3** at 26–39 calls. The
question the first round could not ask — what separates a single pass from a
loop when retrieval is hard — has an answer that is mostly not about
orchestration: the arm whose retrieval a human wrote against the API succeeds
every time, the arm that asks a model to write it reaches the evidence three times in eight,
and the arm that has to discover the API through a boundary that will not name
the bound it violated does not get there at all.

That last clause is a claim about this tool surface, not a verdict on loops.
Give the loop an argument error that says which argument and what the maximum
is, and it may well drain the corpus; item 1 of *Next step* exists to find out.

**"Grounded" is a weaker guarantee than it looked.** Across 101 runs, no
*published* report carried an unresolved identifier or a mismatched digest —
the one draft that did was refused publication, which is the check working. One
loop run nonetheless published a fully grounded report asserting that the
incident did not happen, built from 320 records whose identifiers it had
guessed, none of which were the nine that mattered. Grounding constrains what a
claim may cite and says nothing about what it omits, and a universal negative is
exactly the claim a subset can never support. The first record found a grounded
report that was empty; this one found a grounded report that was wrong.

That run is also the counter-example to reading the abstention result too
warmly. Given a subset, the same arm abstained correctly in one rep and asserted
"no lock waits were recorded" in another. The rule makes abstention *available*;
it does not make a model reliably notice that its evidence is thin — and this
one had been told its coverage was short in neither case, because it had
convinced itself it was complete.

**And a coverage number is only as good as its denominator.** `read_coverage`
was added this round precisely so a retrieval failure would stop reading as a
reasoning failure — and on that run it said 0.96, which would have certified the
opposite. Coverage against the records the oracle names is bimodal, unguessable,
and is the number to read.

## Next step

Items 1–3 of the previous record are **done** and item 5 has run; what follows
replaces them.

1. **Tell a rejected argument what was wrong with it** —
   [#1176](https://github.com/andreasronge/ptc_runner/issues/1176). The loop
   spent an entire run re-sending `limit 100` because `invalid_arguments` names
   neither the argument nor its bound, while both are in the operator's own
   declared `inputSchema`. Same verbatim rule as `invalid_arity` in
   [#1175](https://github.com/andreasronge/ptc_runner/issues/1175). It is the
   single highest-value fix here: it is the only thing standing between the loop
   arm and a real measurement.
2. **Then the guardrail**, unchanged in design from the previous record and now
   much better motivated. The runtime refuses a `return` from an evaluation that
   consumed a truncated result. The kernel must be told which output field means
   incomplete (the `snapshot_identity` block in `ptc-host.json` is the
   precedent), the enforcement point is the evaluation boundary where
   `capability_activity?` is already derived, and it cannot ride on prints
   because those are dropped for every non-`:continued` outcome. The evidence
   that this is the right shape is that **5 of 6 model-written repairs invented
   a cursor** — `loop`/`recur` over an `offset` the API ignores — so the shape
   the model reaches for unprompted is one the tool should either provide or
   refuse to need.
3. **Re-run the loop arm once 1 lands.** Its three rows measure a boundary, not
   an orchestration shape. Nothing about loop-versus-single-pass on a hard
   corpus is settled until the loop can page.
4. **Widen the result contract, or narrow what the model is asked to cite.**
   Three of the four `authored` non-publications are `result_contract_failed`
   from saturating citation caps drawn against 13-record incidents — one report
   with 20 citations on a single fact, another with 160 that all resolved. Cheap
   to change and now clearly wrong; it was left alone only to avoid moving the
   contract mid-comparison.
5. **Fix the corpus generator's identifier scheme** before the next corpus is
   built. See *Open items and traps*.

**Do not** add reps on the 13-record corpus. Those medians are settled — though
note in *Limits* that they describe a report prompt that has since changed.

## Open items and traps

- **The stress corpus numbers its filler predictably, and an arm exploited
  that.** `tools/gen_stress_corpus.exs` gives every source's filler sequential
  identifiers from `prefix-1001`, while the signal records carry unrelated
  numbers. A loop run derived the scheme from one page and enumerated it,
  reaching 320 of 332 records without paging at all. Until identifiers are
  unguessable — opaque, or at least not recoverable from a source listing plus
  `record_count` — a corpus cannot distinguish an arm that retrieved from an arm
  that guessed. Fix this before generating the next corpus; it also
  retrospectively weakens `read_coverage` on any run of this one.
- **`oracle_coverage` is the honest retrieval metric and `read_coverage` is
  not.** Both are recorded. Read the first — and read `coverage_basis` beside
  it, because "records the run fetched" and "records the model was given" are
  not the same set whenever an arm discards a retrieval attempt.
- **`prompt_coverage` counts an outer collection and validates nothing else.**
  No uniqueness, no map shape, no `evidence_id`, no corpus membership. The same
  record repeated, a vector of vectors, or a list of search summaries all report
  as complete. Fixing it means a shape check inside the arms — every element a
  map carrying an `evidence_id` that exists in the corpus — which is the right
  fix and was not applied here only because changing an arm now would
  desynchronise it from the rows it produced.
- **Neither single-pass arm checks that the report names the incident it asked
  about.** A contract-valid report or abstention declaring another
  `incident_id` would be accepted and scored against the requested oracle. No
  run did this; it is a fail-open worth closing before the arms are trusted on a
  multi-incident sweep.
- **The authored arm's repair turn is not monotonic.** In two of eight runs the
  re-authored program returned *fewer* records than the one it replaced (332→8,
  and 160→8). The arm keeps the better of the two only because `fetch-records`
  compares counts explicitly; remove that comparison and a repair makes things
  worse. It also compares *counts*, so a program returning a vector of eight
  per-source vectors looks like eight records and is preferred to nothing.
- **Both single-pass arms count the outer collection.** `(count records)` is the
  arm's whole notion of how much it retrieved, so a nested return is scored as
  its group count. That is how a run with all 332 records fetched reported
  `gathered: 8` and failed its contract. A shape check on the authored program's
  return value — every element a map carrying `evidence_id` — is the missing
  piece `check-source` structurally cannot supply.
- ~~**The authored arm's `evidence.get` failure is undiagnosed.**~~ **Diagnosed
  and fixed.** It was never about call 251: every occurrence was
  `evidence.get chat-7810`, the one record in the fixture set carrying a
  non-ASCII character, refused as `mcp_protocol_error` because the server wrote
  it through a latin1 `:stdio`. See *The undiagnosed failure was one record*.
- ~~**Its baseline at the raised limits is unmeasured.**~~ **Measured.** Told
  only the shortfall, the model's repair moved retrieval 160 → 332 in the runs
  where it worked, and the before-and-after is in the `authoring` annotations
  of every authored trace.
- **Raising a limit rewrites the prompt.** `mission_capability_calls` and
  `mission_capability_calls_per_name` are part of `limit_projection` in
  `mission_inventory.ex`, which is the mission model context handed to the
  authoring call. Changing limits between conditions silently changes the
  input; pin them across any comparison. This confounded the coverage
  experiment here and nothing in the harness flagged it. The 2026-08-04 round
  had to raise the *event* budget mid-flight and checked the projection rather
  than trusting it: `normal_event_count` and `normal_event_bytes` are absent
  from `limit_projection`, and the authoring prompt (10,264 bytes) and report
  prompt (117,114 bytes) are byte-identical across the change. Verify the same
  way rather than reasoning about which fields "should" matter.
- **`check-source` resolves names, not shapes.** Every stress program was
  name-correct, passed the check, and retrieved a fraction of the corpus. With
  retrieval fixed this is now the authored arm's *dominant* failure: a
  vector-of-vectors return, and a `(filterv :found …)` applied after unwrapping
  to the inner record map — where `found` does not exist — which silently
  returned zero records from 160 successful fetches.
- **The stress corpus is regenerable** with
  `mix run incident_compiler/tools/gen_stress_corpus.exs`; the generator
  asserts each oracle token appears in the record it names and in no filler
  record.
- [#1172](https://github.com/andreasronge/ptc_runner/issues/1172) is **fixed**
  by #1174 and verified against this branch. `unbound_var` now names the
  operator's own identifiers and explains the cause —
  `Undefined variables: defn-, priv, x. Hint: 'defn-' defines a private helper
  in component source only; use defn in dynamic source` — and a resource
  directory whose artifacts sit one level down is refused rather than answering
  every query with an empty page. A started session now reports what it
  admitted (`{"traces": {"file_count": 8, "run_count": 8}, ...}`), which catches
  a *partial* capture too. `invalid_arity`, `not_callable` and capability
  failures still collapse to a fixed message, but it now says it is fixed
  ("diagnostic withheld by the private result policy") and every error map
  carries `message_redacted`, so a withheld diagnostic is no longer
  indistinguishable from one that was never produced. `invalid_arity` is the
  highest-value next entry on that allowlist: it cost a round trip here, and
  the function name and arity are both in the operator's own source, so it
  satisfies the existing verbatim rule without weakening it. [#1168](https://github.com/andreasronge/ptc_runner/issues/1168)
  was closed by #1169, which shipped `check-source` and parameterized
  evaluation. [#1167](https://github.com/andreasronge/ptc_runner/issues/1167)
  (promotion) is open and being worked separately.

After those: **the Phase 3 pilot proper**, with bars committed first, and then
the decision about whether `fast` — and now possibly `authored` — becomes a
second shipped entry point beside the loop. This record is evidence for
designing that pilot, not a substitute for it.

The components under `experiments/` are experiment-grade: they work and are
reproducible, but they have no tests and are not part of the shipped
application. The entry-point decision is about which, if any, graduate — at
which point they need the same treatment as anything else in
`incident_compiler/`.

One-off probes used while diagnosing (prompt dumps, shape probes, a
speculate-then-deoptimise hybrid, the `eval-source` capability probes behind
*Runtime capabilities confirmed*) were deliberately not kept. The hybrid is
recoverable from this branch's history if the triage question is reopened.
