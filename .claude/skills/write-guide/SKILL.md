---
name: write-guide
description: Write or edit a page under docs/guides/ so it stays one short, readable, runnable path. Use for every guide edit, including a one-sentence fix.
---

# Write a guide

A guide gets a reader to one outcome by running things. Everything else lives
in a reference page. Read this whole file before touching `docs/guides/`. It
applies to Claude Code, Codex, and Cursor alike; the file path is the contract.

## If you arrived from a bug fix

You may correct a sentence that is wrong. You may not add one. Put the
explanation in the reference page that owns the surface (the CLI, manifest,
host, component, agent-library, limits, or MCP reference) and, if the guide
needs it, leave a link. Then stop.

## Before writing

1. Name the outcome in one sentence. If you cannot, it is not a guide.
2. Find the reference page that owns each surface the guide touches. If a rule
   you need is missing there, add it there first.
3. Run every command you will show and copy the real output.

## Shape

- Title: a verb phrase such as `Debug a failed run`, never a topic.
- First paragraph: one or two sentences saying what the reader ends up with.
  The site uses it as the card text, so no prerequisite, no command, and no
  audience label. It must be at most 160 characters, which is shorter than two
  ordinary sentences; put the rest in a second paragraph.
- One runnable path. A second path is a second page.
- Every step shows the command and what it prints. When the last line is
  deterministic JSON, add the `ptc-guide-e2e` annotation described in
  `docs/maintainers/documentation.md` so the suite runs it.
- At most one caveat per section, one or two sentences long, placed last.
- Closing paragraph: at most three links.
- Length: under 500 words for a task guide, under 1000 for a tutorial.

## What does not belong in a guide

- Error codes and the conditions that raise them.
- Default values, ceilings, and precedence rules.
- Release status, such as "starting with the next release".
- Implementation words: atomic, projection, lease, owner, digest, sealed.
- Anything that answers "what if" instead of "how". That is reference text.
- Prose that already exists in another guide. Link to it instead.

## Voice

Write as one person explaining to another at a keyboard.

- Say what to do before what not to do.
- Address the reader as "you". Keep sentences under about 25 words, one idea
  each.
- Use the contrast "X, not Y" at most once per page.
- Drop intensifiers: deliberately, explicitly, genuinely, simply, merely,
  robust, seamless. Keep "exact" and "bounded" only where they change meaning.
- No em-dashes. Use a full stop, a comma, or parentheses.
- Do not answer objections nobody raised.
- Do not restate what a manifest or mission cannot do unless the page is about
  that boundary. The concepts page owns that sentence.
- Headings may be questions or tasks. Keep one style per page.

## Before you finish

1. `scripts/guide_budget.sh report`: the row is at or under its baseline,
   `blockers` is 0, and `tics` did not rise. If you cut text, run
   `scripts/guide_budget.sh bless` and say so in the commit body.
2. `mix ptc.gen_docs` refreshed `site/guides/`.
3. `MIX_ENV=dev mix docs --warnings-as-errors` and `mix ptc.verify_docs` pass.
4. If you touched a `ptc-guide-e2e` block, run
   `mix test test/quickstart_guide_test.exs`.
5. Read the page once, top to bottom, as the reader. Delete every sentence you
   skipped.
