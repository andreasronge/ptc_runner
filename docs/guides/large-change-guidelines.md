# Guidelines for large and high-risk changes

Use this guide for changes whose correctness depends on several modules,
execution paths, owners, or public contracts. It applies equally to new
features, refactors, and changes that combine both. The relevant question is
not how the work is labelled, but how many invariants and boundaries it can
affect.

Small, local changes do not need this process. Apply it when the structure of
the work makes local reasoning insufficient.

## Recognize a high-risk change

A change deserves explicit design and staged verification when one or more of
the following are true:

- The same concept has multiple representations or apparent owners.
- Equivalent behavior is implemented through direct, callback, asynchronous,
  cached, or generated paths.
- The change crosses a public API, process, persistence, trust, or serialization
  boundary.
- Correctness depends on ordering, cleanup, cancellation, retries, redaction,
  quotas, or resource ownership.
- Adding one field or outcome requires coordinated edits in many modules.
- Existing tests accept several classifications for what should be one stable
  result.
- Recent bugs cluster at transitions between components rather than inside one
  component.
- The intended end state requires deleting or replacing an existing mechanism.

Do not wait for every signal. A single concurrency, authority, confidentiality,
or durable-state invariant can make an otherwise small diff high risk.

## Establish the current state from evidence

Read the implementation, tests, module documentation, guides, and retained
specifications before designing the change. Identify every production entry
point and every parallel implementation path. Do not infer that a mechanism is
missing or unused from names alone.

Record:

- the current authoritative state owners;
- the representations used at each boundary;
- success, failure, cancellation, and cleanup behavior;
- security and visibility constraints;
- limits and accounting responsibilities;
- generated artifacts and documentation that must remain aligned.

A plan should distinguish verified current behavior from proposed behavior.
Plans under `docs/plans/` are temporary working records; durable contracts must
end up in code documentation, guides, or retained specifications. Follow
`docs/guides/documentation-guidelines.md` when choosing the documentation
layer.

## Define contracts before implementation

Write the important invariants in terms that can become tests. Prefer precise
statements such as:

- one component is the sole owner of a mutable resource;
- a reservation is released only after termination is confirmed;
- failed work does not publish candidate state;
- private values never cross the public boundary;
- equivalent entry points produce the same semantic outcome;
- cleanup occurs exactly once on success, failure, timeout, and cancellation.

For behavior with several dimensions, create a small decision table. Useful
dimensions include:

| Dimension | Typical cases |
| --- | --- |
| Outcome | success, expected error, control signal, unexpected failure |
| Entry path | direct, callback, asynchronous, cached, generated |
| Effects | none, recorded before success, recorded before failure |
| Trust | public, private, redacted |
| Lifecycle | normal completion, timeout, cancellation, owner death |

The table is a design aid, not a requirement to create a test for every
mathematical combination. It exposes combinations that would otherwise be
implemented accidentally.

Choose one authoritative representation for each semantic concept. Other
representations should be boundary adapters, not competing sources of truth.
State who creates, transforms, and consumes each representation.

## Plan vertically complete slices

Split work so each phase carries one behavior through all affected layers:

1. Define the contract and its focused tests.
2. Implement the authoritative representation or owner.
3. Migrate every entry and exit path for that behavior.
4. Remove the replaced path instead of maintaining synchronization code.
5. Update durable documentation.
6. Run focused verification before starting the next slice.

Avoid phases that leave two mechanisms authoritative for an extended period.
If an intermediate commit would be internally inconsistent, combine the
dependent edits and keep the conceptual slices explicit in the plan and tests.

For this 0.x library, do not add compatibility layers unless the task
explicitly requires them. A clean replacement is easier to reason about than a
new abstraction wrapped around the old one.

## Test boundaries and invariants

Prefer tests that exercise observable contracts across a boundary. Unit tests
are still useful for a non-trivial algebra, state transition, or classification
function, but they should support rather than replace integration coverage.

Use the following practices:

- For a bug, add a failing regression before changing the implementation.
- Test success and failure after meaningful activity, not only failures that
  occur before work begins.
- Verify metadata, accounting, and cleanup as well as the primary return value.
- Exercise equivalent behavior through every production entry path.
- Test that confidential inputs are absent from all public error, trace, and
  child-result fields.
- Use monitors, messages, barriers, or injectable lifecycle hooks for process
  tests. Do not rely on sleeps or scheduling luck.
- Test the event that authorizes an ownership transition, not merely the state
  observed eventually.
- Preserve an unexpected exception's class and stacktrace unless the public
  contract explicitly normalizes it.

When a defect is found during implementation or review, first reproduce it at
the narrowest stable boundary. Then fix it, run the focused test, and rerun the
broader gate appropriate to the risk.

## Review while the design is still cheap to change

Review high-risk work at semantic checkpoints rather than waiting for the
entire change to be complete. An effective sequence is:

1. Check the proposed invariants and ownership model.
2. Review the first complete vertical slice.
3. Review concurrency, security, persistence, and public-boundary behavior
   adversarially.
4. Perform a final whole-range review, including uncommitted changes.

Ask reviewers to look for missing parallel paths, competing state owners,
information disclosure, cleanup races, documentation drift, and tests that
only confirm the implementation's internal structure.

A clean focused review does not replace repository gates. Conversely, passing
tests do not prove that every production path was identified. Use both.

## Keep the change observable and reversible while developing

Make commits that describe coherent outcomes and state how they were verified.
Keep unrelated work out of the diff. Preserve user changes already present in
the worktree.

During development:

- run the narrowest relevant test after each meaningful edit;
- run formatting, compilation, and static checks before widening the test
  scope;
- inspect the final diff for obsolete code, stale comments, accidental
  compatibility paths, and generated-file drift;
- update code and durable documentation together;
- run `mix precommit` before committing and `mix prepush` before pushing.

## Know when the change is complete

A large change is complete when:

- every stated invariant has evidence in code and tests;
- all production paths use the new authoritative mechanism;
- the replaced mechanism and obsolete adapters are deleted;
- success, failure, timeout, cancellation, and cleanup are covered in
  proportion to their risk;
- security, accounting, and ownership behavior are explicit;
- public and maintainer documentation describe the implemented contract;
- focused tests and repository quality gates pass;
- a final whole-range inspection finds no unexplained parallel behavior or
  stale documentation.

Completion does not require eliminating essential complexity. It requires
making that complexity explicit, localized, and governed by testable
invariants.

## Avoid unnecessary refactoring

Do not introduce a framework merely because several functions look similar.
Duplication can be cheaper than an abstraction when the behaviors have
different owners, failure modes, or likely directions of change.

Refactor when unification creates one clearer authority or removes recurring
boundary defects. Defer it when the proposed abstraction only reduces line
count, hides meaningful differences, or depends on speculative future needs.
