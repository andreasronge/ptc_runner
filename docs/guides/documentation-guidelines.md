# Documentation guidelines

**Audience: people changing PtcRunner itself.** Use this guide when writing
module documentation, guides, specifications, and plans in this repository.
`AGENTS.md` remains the canonical repository instruction file.

## Choose the right documentation layer

- **Module documentation** describes the implemented public API: purpose,
  arguments, return values, errors, ownership, lifecycle, and examples.
- **Guides** explain implemented architecture and user or maintainer workflows.
- **Reference pages** inventory exhaustive implemented fields, options, exports,
  tables, or configuration. Use one when those details would interrupt a
  guide. The [agent library reference](../agent-library-reference.md) is an
  example.
- **Specifications** define normative language or runtime behavior.
- **Plans** describe unimplemented direction, tradeoffs, non-goals, triggers,
  and acceptance gates. Always label planned behavior as planned.

A reference describes the complete current surface; a specification defines
what conforming implementations must do. A page is not normative merely
because it is exhaustive.

`mix.exs` defines the pages published by ExDoc. It includes user guides and
maintainer architecture/gate guides. Checkout-only instructions, including
`docs/development-setup.md` and `docs/RELEASING.md`, stay outside `extras`.
Published pages may name those paths as text, but must not create links that
would dangle on HexDocs.

Keep one canonical explanation and link to it. Move exhaustive tables out of a
guide and into the owning module docs or a retained reference page. Do not copy
field tables, limits, or state machines between layers. Do not present
speculative APIs as current behavior. Git history already records removed 0.x
designs.

Code documentation must not link to `docs/plans/` or other disposable planning
records. Before implementation lands, move durable contracts into owning module
docs, an implemented guide, or a retained specification. Elixir `@spec`
typespecs and links to retained normative references are unaffected.

## Write Elixir API documentation

- Give every public module and function a concise first paragraph. ExDoc uses
  it as the summary.
- Put exact API contracts in `@moduledoc`, `@doc`, `@typedoc`, types, and specs
  beside the implementation.
- Reference modules by full name, such as `PtcRunner.Kernel.TraceLog`.
- Reference functions by name and arity: `query/3` locally or
  `PtcRunner.Kernel.TraceLog.query/3` across modules. Use
  `c:GenServer.handle_call/3` for a callback and
  `t:PtcRunner.Kernel.Result.t/0` for a type.
- Start sections inside module and function documentation with `##`, commonly
  `## Examples`, `## Options`, and `## Errors`.
- Put documentation before the first clause of a multi-clause function. Add a
  function head when pattern matching would produce unclear argument names.
- Use `@moduledoc false` or `@doc false` only for intentionally internal APIs.
  Hiding documentation does not make a function private.
- Use code comments for implementation rationale and workarounds, not as a
  substitute for the public contract. Do not add `@doc` to private functions.

## Examples and doctests

`doctest/1` extracts IEx examples from module and function docs;
`doctest_file/1` extracts them from Markdown. Prefer short, deterministic
examples for public, side-effect-free APIs:

```elixir
## Examples

    iex> PtcRunner.Lisp.Format.to_string([1, 2, 3], limit: 2)
    "[1, 2, ...]"
```

Enable module docs explicitly in a test file:

```elixir
defmodule PtcRunner.Lisp.FormatTest do
  use ExUnit.Case, async: true
  doctest PtcRunner.Lisp.Format
end
```

Markdown uses the file macro:

```elixir
defmodule PtcRunner.DocumentationGuidelinesTest do
  use ExUnit.Case, async: true
  doctest_file("docs/guides/documentation-guidelines.md")
end
```

Doctests are API examples, not behavior-test replacements. Use ordinary ExUnit
for processes, files, networking, time, concurrency, cleanup, complex setup,
and nondeterministic output.

An `iex>` block runs only when a test names its module with `doctest/1` or its
file with `doctest_file/1`.

For a copy/paste CLI example whose final line is deterministic JSON, put this
hidden annotation immediately before its `console` block and place the expected
`json` block immediately after it:

````markdown
<!-- ptc-guide-e2e: id=unique-example-id -->
```console
mix ptc run examples/kernel-tutorial/01-orders/ptc.json
```
```json
{"order_count":3}
```
````

Add `requires=ENVIRONMENT_VARIABLE` when the command needs a credential. The
helper in `test/support/guide_examples.ex` turns each annotation into an ExUnit
test that runs the literal shell block from the repository root, requires a
zero exit status and empty standard error, and compares the last standard-output
line as JSON. Credentialed examples receive the `:scheduled_e2e` tag. Keep
setup, cleanup, secrets, and nondeterministic assertions in the test harness;
the visible block must remain useful when pasted by a reader.

## Style and tone

- Write for the API user or maintainer, leading with what the component does.
- Use plain language, active voice, and present tense for implemented behavior.
- Use `must` for normative requirements, `may` for permitted choices, and
  explicit future tense for plans.
- Keep paragraphs short and focused. Use lists or tables only when they make a
  relationship easier to scan.
- Use real current module, function, option, and error names. Verify them in the
  implementation before documenting them.
- Keep examples domain-neutral unless the API itself is domain-specific.
- State security, bounds, side effects, ownership, and failure behavior where
  users need them; do not bury important constraints in implementation notes.

## Update and verify documentation

When behavior changes, update the owning module docs, relevant guide or
specification, tests, examples, and generated references together. Generated
`docs/function-reference.md`, `docs/java-interop.md`, and
`docs/conformance/` pages must be changed through their `priv/*.exs` sources
and `mix ptc.gen_docs`, not edited directly.

Run focused doctests or documentation tests, then:

```bash
MIX_ENV=dev mix docs --warnings-as-errors
mix precommit
```

Do not claim a check passed without its successful final exit status.

References: the official Elixir guides for
[writing documentation](https://hexdocs.pm/elixir/writing-documentation.html)
and [`ExUnit.DocTest`](https://hexdocs.pm/ex_unit/ExUnit.DocTest.html).
