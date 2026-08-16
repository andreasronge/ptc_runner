# Interactive REPL line editing

**Status:** planned. The interactive `ptc repl` loop reads through `IO.gets/1`
under a `-noshell` VM, so the terminal supplies only canonical-mode editing.
Emacs keys, arrow keys, and history are delivered to the loop as raw bytes.

Implemented behavior belongs in
[Running and debugging](../../guides/running-and-debugging.md) and
`PtcRunner.ReplFrontend` module documentation once this lands.

## Goal

Give the interactive REPL the line editing every shell user expects —
`Ctrl+A`/`Ctrl+E`, word motion, kill and yank, arrow-key history, and reverse
search — in both the Mix frontend and the assembled standalone release,
without adding a dependency or a hand-written terminal editor.

This does not change command grammar, envelopes, diagnostics, evaluation
semantics, or any non-interactive input path.

## Observed behavior

Both frontends boot the VM with `-noshell` (`mix`, and the release's bundled
`releases/<vsn>/elixir`). In that mode `IO.gets/1` returns the raw line:

```
typed  abc <Ctrl+A> X   ->  <<97, 98, 99, 1, 88, 10>>
typed  <Up>            ->  "\e[A\n"
```

## Mechanism

OTP already contains the editor — `user_drv`, `group`, and `edlin`, the same
stack `iex` uses. `-noshell` starts the plain reader instead. `shell` can
switch the running VM to the interactive reader and accept the process that
acts as its shell, so the existing loop becomes that process and keeps reading
with `IO.gets/1`.

Properties of the switch that the implementation must respect:

- **The start tuple runs inside the group process and must return a pid.**
  Calling `IO.gets/1` from the applied function returns
  `{:error, :calling_self}`, because the applied function *is* the group.
- **The new group is a fresh IO server with default options.** The shell
  process re-establishes binary UTF-8 mode first, or the loop receives
  charlists and every `String` call on the line fails.
- **The switch is one-way and VM-global.** OTP has no `stop_interactive`
  counterpart, and a second call returns `{:error, :already_started}`.
  Installing the reader is therefore a terminal-ownership decision taken once,
  by the interactive REPL, as the last thing the command does. Any unexpected
  `start_interactive/1` return falls back to today's reader rather than
  failing the command.
- **The shell process parks after reporting its result.** `user_drv` restarts
  a shell that terminates, so parking keeps session teardown in the caller,
  where it already is. The parked process does not delay VM shutdown.
- **Failure must cross the process boundary.** The loop currently runs inside
  `run_workflow_session/3`, whose `rescue`/`catch` aborts the session on a
  frontend exception. Moving the loop into another process silently disarms
  that handler. The child therefore catches, reports `{kind, reason,
  stacktrace}` to the caller, and the caller re-raises it so the existing
  abort path fires unchanged. The caller also monitors the child, so a child
  that dies without reporting — killed, or failing before its `try` — exits
  with that reason instead of blocking the command forever.
- **The terminal gate decides.** `AnalysisTerminal.attached?/0`
  (`lib/ptc_runner/kernel/analysis_terminal.ex`) admits the switch. Without a
  terminal the interactive reader prints an OTP banner and takes over piped
  input, so redirected stdin, `capture_io/1` tests, and every CI path keep the
  current reader.

## Scope

**Line editing** covers the interactive loop reached by `evaluate_mode/3` —
direct and manifest workflow sessions alike (`interactive/1`, `loop/1`).

**Persistent history is narrower than line editing.** `kernel`'s
`shell_history` writes every submitted line to disk. A manifest session can
carry a private event policy and sensitive input, so only the direct session —
the scratch pad with no manifest behind it — enables it. Manifest sessions
line-edit with in-memory history only. That decision is a pure function of the
session mode, and is unit-tested as one rather than inferred at the call site.

**The profile and private-manifest analysis REPL keeps today's reader.**
`interactive_profile/3` and `profile_loop/3` read one character at a time
through `read_bounded_line/4` to enforce `--profile` source limits, and the
interactive reader line-edits and re-echoes the remaining buffer on every
one-character read. That path is unchanged until its byte limit is expressed
as a whole-line check, and the guide states the limitation rather than leaving
it implied.

## Consequences to absorb

**`Ctrl+D` stops meaning end of input.** In the interactive reader `^D` is
forward-delete; `kernel/group.erl` records the split, and the configurable
`shell_keymap` has no binding that produces end of input. The REPL gains a
`:quit` command, which the plain loop must act on directly: `handle_command/2`
returns `:ok` and cannot terminate a loop today. Because the profile loop
keeps `Ctrl+D`, the two banners legitimately differ — the plain banner names
`:quit`, the profile banner keeps `Ctrl+D` — and the shared `:help` text names
both only where each applies.

**`Ctrl+C` changes meaning.** Under the plain reader it terminates the VM.
Under the interactive reader it opens the BEAM break menu — `(a)bort`,
`(c)ontinue` — exactly as in `iex`. This is recoverable but unfamiliar to
anyone who has only used `ptc repl`, so the guide states it. Independently of
that menu, `IO.gets/1` can return `{:error, reason}` on an interrupted read,
which `read_expression/2` currently concatenates to its buffer and crashes on;
both readers must handle an error return as a failed read.

**The banner must come from the reader, not from the caller.** `user_drv`
prints `stdlib`'s `shell_slogan` when it starts, and a banner printed by the
calling process races the first prompt. Setting the slogan replaces the
`Erlang/OTP …` line rather than adding to it.

**Configuration is VM-global and start-ordered.** `shell_slogan`,
`shell_history`, and `shell_history_path` are read when the reader starts, so
the command sets them before the switch and never mutates them afterwards. The
history directory is PtcRunner-owned under the user cache — not the shared
Erlang history — and is created owner-only, because it holds transcript lines.

## Deferred

Tab completion. `io:setopts/2` accepts an `expand_fun`, the interactive reader
renders its candidate list, and the REPL already owns a builtin catalog
(`:find`), so completing builtin and prelude names is a small follow-on. It is
excluded here to keep one reviewable mechanism per slice; the expansion
callback receives the reversed line, not a token, and needs its own tests.

## Verification

The interactive path activates only when stdin is a terminal, which is exactly
what the existing suites cannot provide, so the fix would otherwise ship
untested. Add a pseudo-terminal assertion to
`scripts/verify_standalone_release.sh`, beside the existing `repl -e` check,
driving the packaged `bin/ptc`:

- type a partial expression, use `Ctrl+A` and `Ctrl+E` to complete it, submit
  it, and assert the evaluated result;
- recall it with the up arrow and assert the same result;
- leave with `:quit` and assert a zero status; and
- start a second process against the same history path and assert the previous
  process's line is recalled.

That gate already runs under `mix precommit`, the pre-push hook, and CI, and it
tests the shipped artifact rather than the Mix task. The gate is mandatory: it
fails when `expect(1)` is missing, and the workflow job installs it, so no
platform can silently ship an unverified editor. A documented environment
variable skips it only where a maintainer knowingly accepts that.

Two assertions do not need a terminal and belong in ExUnit: the mode-to-history
decision, and the unchanged non-interactive contract under `capture_io/1`.

## Acceptance

1. `Ctrl+A`, `Ctrl+E`, word motion, kill/yank, arrow history, and reverse
   search work in `mix ptc repl` and in the packaged `bin/ptc repl`.
2. Redirected stdin, `--eval`, script arguments, and `-` are byte-identical to
   today, and no OTP banner appears on any non-terminal path.
3. `:quit` leaves through the existing session teardown; a failing loop still
   reaches the frontend-exception abort; and the guide, module documentation,
   and banners agree on how to exit and what `Ctrl+C` now does.
4. A direct session persists history under the PtcRunner cache path; a manifest
   session writes none.
5. The pseudo-terminal gate fails if the interactive reader stops being
   installed.
