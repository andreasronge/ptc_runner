# Documentation Guidelines

Writing documentation for Elixir projects using HexDocs.

## First Paragraph Rule

Keep the first paragraph concise (typically one line). Tools extract this for summaries.

```elixir
@doc """
Executes a SubAgent and returns the result.

Takes a prompt or SubAgent struct and runs it through the agentic loop
until completion or failure.
"""
```

## Tone

- **Direct**: Use imperative mood ("Run the command" not "You should run")
- **No fluff**: Avoid "simply", "just", "easily"
- **Technical but approachable**: Explain "why" alongside "how"

## Structure

**Module docs (`@moduledoc`):**
1. One-line summary
2. Overview (2-3 sentences)
3. `## Examples`
4. Detailed sections
5. `## Options` (if applicable)

**Guides:**
1. What this covers (1-2 sentences)
2. Prerequisites (if any)
3. Content (progressive complexity)
4. See Also / cross-links

## Formatting

| Element | Convention |
|---------|------------|
| Module refs | `` `PtcRunner.SubAgent` `` |
| Function refs | `` `run/2` `` local, `` `SubAgent.run/2` `` external |
| Type refs | `` `t:Step.t/0` `` |
| Callback refs | `` `c:llm_callback/1` `` |
| Options | Bullet list: `:option` - Description |
| Headings | `##` for sections (never `#`) |

### Auto-linking in Guides

In markdown guides (extras), only **function references with arity** auto-link:

| Reference | In `@doc`/`@moduledoc` | In guides (`.md`) |
|-----------|------------------------|-------------------|
| `` `PtcRunner.SubAgent` `` | Links ✓ | Code only, no link |
| `` `PtcRunner.SubAgent.run/2` `` | Links ✓ | Links ✓ |

To link from guides, always include the arity:

```markdown
<!-- Won't link in guides -->
See `PtcRunner.SubAgent.Telemetry` for details.

<!-- Will link in guides -->
See `PtcRunner.SubAgent.Telemetry.span/3` for details.
```

## Code Examples

Use `iex>` prompt for doctests:

```elixir
## Examples

    iex> SubAgent.run("Hello", llm: fn _ -> {:ok, "(return 42)"} end)
    {:ok, %Step{return: 42}}
```

## Guides vs Module Docs

| Guides | Module Docs |
|--------|-------------|
| Conceptual, tutorial-style | API reference |
| Multiple modules | Single module focus |
| "How to achieve X" | "What does Y do" |
| Progressive workflow | Minimal examples showing *flavor* |

**Complement, don't duplicate.** Guides teach workflows progressively; module docs orient users to the API. Link between them:

```markdown
<!-- In guides: link to module docs for API details -->
See `PtcRunner.SubAgent.run/2` for all options.

<!-- In module docs: link to guides for tutorials -->
See the [Getting Started Guide](guides/subagent-getting-started.md) for a walkthrough.
```

## Entry Point Modules

The main library module (e.g., `PtcRunner`) serves as an **architectural roadmap**, not a tutorial.

**Structure:**
1. One-line summary
2. Overview (2-3 sentences)
3. Component table mapping modules to purpose
4. One minimal example showing the primary workflow
5. Links to guides

**Example component table:**

```elixir
@moduledoc """
...

## Core Components

| Component | Purpose |
|-----------|---------|
| `PtcRunner.SubAgent` | Agentic loop - prompt → LLM → execute |
| `PtcRunner.Lisp` | PTC-Lisp interpreter |
| `PtcRunner.Sandbox` | Isolated execution |
"""
```

This gives users a mental model before diving into specifics. Keep examples minimal—enough to show flavor, not enough to teach.

## Brevity

- Paragraphs: 2-4 sentences max
- Guide sections: <30 lines (split or move to module docs)
- Prefer linking over explaining

```markdown
<!-- Don't: restate module docs -->
The `max_turns` option limits iterations. Default is 10...

<!-- Do: show usage, link for details -->
Limit iterations with `max_turns`. See `PtcRunner.SubAgent.run/2` for all options.
```

## What NOT to Document

- Implementation details (use code comments)
- Private functions (use `@doc false`)
- Obvious behavior
- Future plans or TODOs

## Audience

Guides are for library users, not contributors.

- Use `MyApp.*` namespaces in examples (not internal modules)
- Focus on public API usage
- Assume readers installed the library as a dependency

## File Naming

| Location | Pattern |
|----------|---------|
| SubAgent guides | `subagent-<topic>.md` |
| General guides | `<topic>.md` |
| Guidelines | `<topic>-guidelines.md` |
