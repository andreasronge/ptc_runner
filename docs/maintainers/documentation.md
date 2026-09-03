# Documentation guidelines

> **Audience:** people changing PtcRunner itself.

Use this guide when writing
module documentation, guides, specifications, and plans in this repository.
`AGENTS.md` remains the canonical repository instruction file.

## Choose the right documentation layer

- **Module documentation** describes the implemented public API: purpose,
  arguments, return values, errors, ownership, lifecycle, and examples.
- **Installation pages** describe one supported distribution route, its
  prerequisites, verification, and platform-specific security properties.
- **Guides** are short end-user workflows that accomplish one outcome. They
  show one useful path and link to reference pages for exhaustive detail.
- **Reference pages** inventory exhaustive implemented fields, commands,
  options, exports, tables, schemas, or configuration. Use one when those
  details would interrupt a guide. The
  [agent library reference](../agent-library-reference.md) is an example.
- **Maintainer pages** explain repository architecture, implementation APIs,
  local gates, conformance work, and release procedures. They live only under
  `docs/maintainers/`.
- **Specifications** define normative language or runtime behavior.
- **Plans** describe unimplemented direction, tradeoffs, non-goals, triggers,
  and acceptance gates. Always label planned behavior as planned.

A reference describes the complete current surface; a specification defines
what conforming implementations must do. A page is not normative merely
because it is exhaustive.

`mix.exs` defines the pages published by ExDoc. It includes installation pages,
user guides, retained references, and selected maintainer architecture/gate
guides. Checkout-only instructions, including
`docs/maintainers/development-setup.md` and
`docs/maintainers/releasing.md`, stay outside `extras`.
Published pages may name those paths as text, but must not create links that
would dangle on HexDocs.

Keep one canonical explanation and link to it. Move exhaustive tables out of a
guide and into the owning module docs or a retained reference page. Do not copy
field tables, limits, or state machines between layers. Do not present
speculative APIs as current behavior. Git history already records removed 0.x
designs.

Public prose in `README.md`, `docs/guides/`, and `docs/reference/` describes
the executable, JSON documents, PTC-Lisp boundary, capabilities, limits, and
artifacts without explaining behavior through the implementation language.
Implementation-language guidance belongs in installation pages when a source
build requires it, API/module documentation, the package `usage-rules.md`, or
`docs/maintainers/`.

Every hand-written guide and installation page starts with a plain summary of
one or two sentences after its title. The site uses the first paragraph for
cards and metadata, so it must describe the outcome instead of opening with a
prerequisite, command fragment, or internal audience label. Reference pages
start with a short scope statement. Maintainer pages may keep a visible
audience statement when it helps distinguish repository work from product use.

Published product prose addresses the reader as `you` when needed and names
the file that owns a decision. Prefer `ptc-host.json installs` and `ptc.json
selects` over invented roles such as "operator" or "application author". Team
ownership varies; the two-file boundary does not. Security references may use
`authority` when it describes a precise permission contract, but guides should
name the model, tool, data, or limit that is actually available.

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
  doctest_file("docs/maintainers/documentation.md")
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
<!-- ptc-guide-e2e: id=unique-example-id project=examples/kernel-tutorial/01-orders.ptc-project.json -->
```console
mix ptc run examples/kernel-tutorial/01-orders.ptc-project.json
```
```json
{"order_count":3}
```
````

Add `requires=ENVIRONMENT_VARIABLE` when the command needs a credential. Add
`frontend=mix` to an end-user `ptc` block when the test should run the same
arguments through the source-checkout `mix ptc` frontend; standalone packaging
is verified by the release gate. The
helper in `test/support/guide_examples.ex` turns each annotation into an ExUnit
test after the guide path is added to
`test/support/executable_guides.txt`. That registry is shared by the test,
CI classifier, and pre-push hook. The test runs the literal shell block from the
repository root, requires a zero exit status and empty standard error, and
compares the last standard-output line as JSON. Credentialed examples receive
the `:scheduled_e2e` tag.
`assert=two-turn-agent` additionally points `PTC_ENVELOPE_FILE` at the test's
owner-only temporary directory and verifies two model calls, two subordinate
evaluations, and the committed continuation in the command envelope. Keep
setup, cleanup, secrets, and nondeterministic assertions in the test harness;
the visible block must remain useful when pasted by a reader. Because routing
comes from the registry rather than current file contents, removing the final
annotation or deleting a registered page still runs both documentation and
core test gates.

Add `project=path/to/ptc-project.json` when the visible command runs a shipped
project configuration. The helper copies the project directory into its
owner-only temporary directory, substitutes only that exact command argument,
removes copied artifacts, writes a required credential to the copied project's
declared environment file, and reads asserted envelopes from the copied
artifact root. The checked-out example therefore remains unchanged while the
test exercises the same project document, relative paths, and command form a
reader uses.

## Style and tone

The guide voice, page shape, and the words to avoid live in the guide skill at
`.claude/skills/write-guide/SKILL.md`; every edit under `docs/guides/` starts
there. These rules apply to every layer:

- Use `must` for normative requirements, `may` for permitted choices, and
  explicit future tense for plans.
- Use real current module, function, option, and error names, verified in the
  implementation before documenting them.
- Keep examples domain-neutral unless the API itself is domain-specific.
- Define a term on first use when the reader needs it to complete the page,
  and link to the concepts or reference page for the rest of the vocabulary.
- Reference pages state security, bounds, side effects, ownership, and failure
  behavior where users need them; guides link to that statement.

## Update and verify documentation

When behavior changes, update the owning module docs, relevant guide or
specification, tests, examples, and generated references together. Generated
`docs/function-reference.md`, `docs/java-interop.md`,
`docs/kernel-limits-reference.md`, `docs/prelude-reference.md`,
`docs/conformance/` pages, and `priv/preludes/kernel/agent.failure.clj` must
be changed through their owning source catalogs and `mix ptc.gen_docs`, not
edited directly. The same applies to the static-site guide pages under
`site/guides/`: they are rendered from `docs/guides/` by
`mix ptc.gen_site_guides` (which `mix ptc.gen_docs` runs), with sections read
from the guide groups in `mix.exs` — edit the guide Markdown or the groups,
never the HTML. `docs/reference/cli.md` is hand-written apart from the
exit-status and profile diagnostic catalogs between their `BEGIN GENERATED`/
`END GENERATED` markers. The same task rewrites them from
`PtcRunner.Kernel.DiagnosticCatalog` and
`PtcRunner.ProfileDiagnosticCatalog`, respectively.

Run focused doctests or documentation tests, then:

```bash
MIX_ENV=dev mix docs --warnings-as-errors
mix precommit
```

Do not claim a check passed without its successful final exit status.

References: the official Elixir guides for
[writing documentation](https://hexdocs.pm/elixir/writing-documentation.html)
and [`ExUnit.DocTest`](https://hexdocs.pm/ex_unit/ExUnit.DocTest.html).
