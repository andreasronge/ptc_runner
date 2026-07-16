# Documentation guidelines

Use this guide when writing module documentation, guides, specifications, and
plans. `AGENTS.md` remains the canonical repository instruction file.

## Choose the right documentation layer

- **Module documentation** describes the implemented public API: purpose,
  arguments, return values, errors, ownership, lifecycle, and examples.
- **Guides** explain implemented architecture and user or maintainer workflows.
- **Specifications** define normative language or runtime behavior.
- **Plans** describe unimplemented direction, tradeoffs, non-goals, triggers,
  and acceptance gates. Always label planned behavior as planned.

Keep one canonical explanation and link to it instead of copying contracts
between files. Do not present speculative APIs as current behavior. Git history
records removed 0.x designs, so current documentation does not need migration
narratives or deprecated alternatives.

Code documentation must not link to implementation plans or planning
specifications, including files under `docs/plans/`. Those files are disposable
working records and may be deleted when the implementation lands. Before a
planned feature is complete, move its durable contract into the owning module
documentation and an implemented guide or retained normative specification.
Then code documentation links only to those retained documents.

This rule does not prohibit Elixir `@spec` typespecs, or links to retained
normative references such as the PTC-Lisp language specification.

## Write Elixir API documentation

- Give every public module and function a concise first paragraph. ExDoc uses
  it as the summary.
- Place exact API documentation in `@moduledoc`, `@doc`, `@typedoc`, types, and
  specs beside the implementation.
- Reference modules by full name, such as `PtcRunner.Kernel.TraceLog`.
- Reference functions by name and arity: `query/3` locally or
  `PtcRunner.Kernel.TraceLog.query/3` across modules. Use
  `c:GenServer.handle_call/3` for a callback and
  `t:PtcRunner.Kernel.Result.t/0` for a type.
- Start sections inside module and function documentation with `##`, commonly
  `## Examples`, `## Options`, and `## Errors`.
- Put documentation before the first clause of a multi-clause function. Add a
  separate function head when pattern matching would produce unclear argument
  names in generated documentation.
- Use `@moduledoc false` or `@doc false` only for intentionally internal APIs.
  Hiding documentation does not make a function private.
- Use code comments for implementation rationale and workarounds, not as a
  substitute for the public contract. Do not add `@doc` to private functions.

## Examples and doctests

ExUnit supports executable tests embedded in documentation. `doctest/1`
extracts IEx examples from `@moduledoc` and `@doc`; `doctest_file/1` extracts
them from Markdown files. Prefer short, deterministic examples for public,
side-effect-free APIs:

```elixir
## Examples

    iex> PtcRunner.Lisp.Format.to_string([1, 2, 3], limit: 2)
    "[1, 2, ...]"
```

Enable module documentation explicitly in an ExUnit test file:

```elixir
defmodule PtcRunner.Lisp.FormatTest do
  use ExUnit.Case, async: true
  doctest PtcRunner.Lisp.Format
end
```

Markdown documentation uses the corresponding file macro:

```elixir
defmodule PtcRunner.DocumentationGuidelinesTest do
  use ExUnit.Case, async: true
  doctest_file("docs/guides/documentation-guidelines.md")
end
```

Doctests are executable API examples, not a replacement for behavior tests.
Use ordinary ExUnit tests for processes, files, networking, time, concurrency,
cleanup, complex setup, or nondeterministic output. The embedded doctest syntax
is `iex>` plus expected output; ordinary `test "..."` cases remain in test
files unless the document specifically teaches ExUnit usage.

When adding `iex>` examples, verify that the module is covered by `doctest/1`
or the Markdown file by `doctest_file/1`; examples are not discovered globally.

## Style and tone

- Write for the API user or maintainer, leading with what the component does.
- Use plain language, active voice, and present tense for implemented behavior.
- Use `must` for normative requirements, `may` for permitted choices, and
  explicit future tense for plans.
- Keep paragraphs focused and headings descriptive. Avoid filler, sales
  language, and restating names without adding meaning.
- Use real current module, function, option, and error names. Verify them in the
  implementation before documenting them.
- Keep examples domain-neutral unless the API itself is domain-specific.
- State security, bounds, side effects, ownership, and failure behavior where
  users need them; do not bury important constraints in implementation notes.

## Update and verify documentation

When behavior changes, update the owning module documentation, the relevant
guide or specification, tests, examples, and generated references together.
Run the focused doctests or documentation tests, then `mix precommit` before
committing. Do not claim an example or check passed without a successful final
exit status.

References: the official Elixir guides for
[writing documentation](https://hexdocs.pm/elixir/writing-documentation.html)
and [`ExUnit.DocTest`](https://hexdocs.pm/ex_unit/ExUnit.DocTest.html).
