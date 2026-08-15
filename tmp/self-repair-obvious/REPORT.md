# Obvious prelude self-repair experiment

Date: 2026-08-15

Runtime: current `origin/main` at `53d691438dcebbbb2f46c605d12efa214acf1c18`

## Result

Yes. A second PTC run can identify one faulty prelude and function, explain the
violated invariant from immutable trace and inspection evidence, author complete
replacement source with the exact captured base hash, pass the real materializer,
and prove the repair in fresh Luna and DeepSeek runs without replay.

The smallest successful interface in this experiment was one coarse operation,
`debug.context/latest-failure`, that:

1. selects one captured failed run;
2. reads its execution errors and reconstructed turns;
3. derives the prelude component identities referenced by generated programs;
4. reads only those complete prelude sources.

The debugger keeps raw `debug.evidence/open` and `debug.evidence/read` as a
fallback, but Luna did not need them with the targeted context response.

## Success ladder

| Milestone | Evidence |
|---|---|
| Attribution | Luna debugger `cmd-7wexrhjeye5qt97qnsf5pp4vba` named component `claims` and function `claims/submit`. |
| Explanation | It cited the captured implementation returning `"Done"` and turn feedback `prelude_contract_error: claims/submit output: expected map, got string`. |
| Repair | It returned complete source with base hash `sha256:f5d976b3774b2c307ffc8080234fd082549e4d60492639e47b4cb8c45a3aca62`. |
| Static proof | `ptc.materialize` passed G1-G4 and published candidate hash `sha256:344b3b944152ed48ad593f930c8003efb20e45ae7ca37f987e3674d2b6668f11`. |
| Behavioral proof | Fresh Luna run `cmd-7yffz9af0hbvyre1tj2h9m1n9f` succeeded in one call. |
| Independent proof | Fresh DeepSeek run `cmd-1s42j5d54qts5ew2g1zk4q4xt4` succeeded in one call with the same result hash. |
| Iteration | No behavioral revision was needed. A separately authored DeepSeek candidate also passed G1-G4 and fresh Luna and DeepSeek validation. |

## Main measurements

| Run | Model | Interface/outcome | LLM calls | Evidence calls | Duration |
|---|---|---|---:|---:|---:|
| `cmd-5x147m61b4c2c9n40dxvcs62sk` | Luna | Deliberately faulty target; expected failure | 2 | 0 | 25.2s |
| `cmd-59ddyb1bzrm201t30yzf470jba` | Luna | Raw hypermedia; correct repair | 11 | 9 | 25.1s |
| `cmd-2775vhjskr2w2kfvqck4y6ngy1` | Luna | Broad coarse context; correct repair | 7 | 9 | 18.1s |
| `cmd-7wexrhjeye5qt97qnsf5pp4vba` | Luna | Targeted coarse context; correct repair | 2 | 4 | 7.85s |
| `cmd-6mt0f4f9zw2qkzsth57mvrk4md` | DeepSeek | Targeted context; correct source but unqualified `function_id` | 2 | 4 | 19.6s |
| `cmd-3jp0skpvjd8ec90483msh51y24` | DeepSeek | Targeted context after contract clarification; qualified identity | 3 | 5 | 32.3s |
| `cmd-7pq558cdv9nkzt5vh3ay67ya8g` | Luna | Targeted context plus in-loop materializer | 3 | 5 | 13.2s |

All measurements above were read back through the
`private-run-analysis-v1` PTC profile, not inferred from console text alone.

## Fresh validation

Luna-authored candidate:

- Luna `cmd-7yffz9af0hbvyre1tj2h9m1n9f`: one LLM call, 3.31s, zero execution errors.
- DeepSeek `cmd-1s42j5d54qts5ew2g1zk4q4xt4`: one LLM call, 4.91s, zero execution errors.
- Both returned exactly `{"claims": ["The main pool reopened on 14 April.", "The spa remains closed."]}`.
- Both recorded candidate source hash `sha256:344b3b944152ed48ad593f930c8003efb20e45ae7ca37f987e3674d2b6668f11` and the captured base hash.

DeepSeek-authored candidate using `{:claims claims}`:

- Materializer G1-G4 passed with source hash `sha256:ac25a7579e9fc9c61ae5adc13b7a337d643bcf4458ae18343fa429ca7d26bd23`.
- Luna `cmd-3qfqfczyvn5ktsw3dscrwr6m10`: one LLM call, 2.27s, zero execution errors.
- DeepSeek `cmd-5fmbrds2z4846zqhj441ze6t4q`: one LLM call, 3.98s, zero execution errors.
- Both produced the same exact application result and result hash as the Luna-authored candidate.

## Interface decision

- Keep a coarse `debug.context/latest-failure`-style operation. It reduced the
  successful Luna path from 11 model calls to 2 by returning only the generated
  turns, errors, and sources for preludes those turns actually referenced.
- Keep raw `open/read` navigation as fallback, not as the default discovery path.
- Do not require an in-loop `debug.repair/check-candidate` for this basic case.
  It worked and proved G1-G4 inside the debugger run, but added one model call,
  an MCP provider boundary, and about 5.4s versus host-side materialization.
- Use the host loop as the minimal repair protocol: debugger publishes a tagged
  candidate; host runs `ptc.materialize`; host launches a fresh validation run;
  PTC analyzes the validation trace. Add in-loop checking only when rejected
  candidates need model correction before publication.

## Friction observed

1. The shipped `analysis` prelude uses profile-only `analysis-*` capability
   names. An ordinary manifest selecting snapshot providers receives
   provider-scoped names such as `private-history.read`, so it needs a thin
   custom wrapper.
2. Luna initially wrapped an exploratory evidence call in `(return ...)`, which
   terminated the evaluation. The generic REPL rule must be explicit: ordinary
   expressions observe; `return` is only for the final report.
3. Raw navigation consumed most of the turn budget and produced one invalid
   nested `filters` query. Snapshot filters are top-level keys.
4. Returning all effective prelude sources made the coarse response too broad;
   Luna reopened and reread evidence. Deriving called component identities and
   returning only those sources reduced the run to two calls.
5. Tagged-result packaging was unreliable until the exact flat field names and
   `validation_plan` shape were stated in the task.
6. The application result-contract subset rejected a JSON Schema `pattern`
   used to require namespace-qualified function identities, reporting only
   `application/contract_invalid`. The requirement had to remain in task text.
7. Provider-acquisition and contract-preflight failures produced no canonical
   run trace, so PTC could not analyze them; only the command diagnostic existed.
8. The target's `execution_errors` collection contained a generic workflow
   failure. The exact `prelude_contract_error` was available in reconstructed
   turn feedback, so an incident context must include both.
9. G1-G4 establish structural fitness, not semantic correctness. Fresh live
   validation remains mandatory even for this obvious repair.

## Scope deliberately excluded

No replay, Viewer change, automatic installation, production-code change,
general graph API, PR, commit, push, or GitHub mutation was performed.
