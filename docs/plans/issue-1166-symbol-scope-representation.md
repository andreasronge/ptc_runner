# Issue #1166 item 2 — a user definition whose name interns to an atom is reported undefined

Status: implemented — see the Outcome section at the end.
Scope: `lib/ptc_runner/lisp.ex` static undefined-variable check only.

## Symptom

A component (or prelude) that defines a function named `parse` fails to
compile, and the diagnostic blames the user's own definition:

```console
$ mix ptc validate probe/ptc.json
** (Mix) error: bundle/undefined_variable: Undefined variable: parse
```

Renaming the function to `parse-report` compiles. The same source with
`between` or `currentTimeMillis` fails the same way.

Reported as item 2 of #1166, with the hypothesis "unqualified Java member
names are reserved". That hypothesis is wrong — nothing reserves these names.
The real cause is a representation asymmetry in the static scope check.

## Root cause

`SourceAtoms.intern/1` (`lib/ptc_runner/lisp/source_atoms.ex:61-63`) returns an
**atom** when the name is in the bounded-vocabulary table and the **binary**
otherwise. The table is an atom-safety allowlist, so which representation a
symbol gets is an artifact of that allowlist, not a language rule:

```
parse          intern=:parse             # atom  — in the table
parse-report   intern="parse-report"     # binary
now            intern="now"              # binary
```

`parse` is in the table because `priv/java_interop.exs:1324,1330,1336,1342`
declares `source_name: :parse` (an atom) for `LocalDate/parse` and
`Instant/parse`; `BuiltinNames.java_member_atoms/0`
(`lib/ptc_runner/lisp/builtin_names.ex:51-58`) collects those atoms and
`SourceAtoms.build_table/0` (`source_atoms.ex:150-166`) folds them into the
table. Sibling entries in the same file use strings (`"parseInt"`,
`"parseLong"`, `"parseDouble"`), which is why they are unaffected.

The parse tree therefore mixes representations within one form:

```elixir
list: [symbol: "defn-", symbol: :parse,  vector: [symbol: "x"], symbol: "x"]
list: [symbol: :defn,   symbol: "run", ...]
```

The static check does not tolerate that mix. `collect_undefined_vars/2`
(`lib/ptc_runner/lisp.ex:2620-2628`) resolves a reference through
`scope_member?/2` (`lisp.ex:2864-2871`), which bridges **binary name → atom in
scope** but not the reverse:

```elixir
defp scope_member?(scope, name) do
  MapSet.member?(scope, name) or
    (is_binary(name) and
       case safe_to_existing_atom(name) do
         {:ok, atom} -> MapSet.member?(scope, atom)
         :error -> false
       end)
end
```

`Prelude.Compiler.check_prelude_vars/2`
(`lib/ptc_runner/lisp/prelude/compiler.ex:1644-1659`) seeds the scope from
`ns_specs` symbols, which `symbol_name/1` (`compiler.ex:696`) has already
stringified; `spec_to_defn_form/1` (`compiler.ex:1662-1670`) then rebuilds the
definition around that stringified name while the body keeps its original
atom-backed references. So the scope holds `"parse"` while the reference is
`:parse`, and the missing atom → binary direction reports it undefined.

The runtime resolver has no such gap: `Eval.resolve_user_ns/3`
(`lib/ptc_runner/lisp/eval.ex:921-932`) bridges atom → binary and
`resolve_legacy_user_ns/3` (`eval.ex:955-963`) bridges binary → atom. Only the
static pre-execution check is one-way.

## Blast radius

Not limited to Java member names. Every one of the six table sources in
`SourceAtoms.build_table/0` (`source_atoms.ex:150-166`) contributes, because
only direct-dot Java spellings are rejected as definition names
(`lib/ptc_runner/lisp/analyze/patterns.ex:58`) — the rest are legal.

Measured by compiling `(defn- NAME [x] x)` plus a sibling call for all 380
current table keys: **68 names reproduce the failure.**

```
&  Boolean  Double  Duration  Float  Instant  Integer  LocalDate  Long  Math
NEGATIVE_INFINITY  NaN  POSITIVE_INFINITY  System  as  between  clojure.core
clojure.set  clojure.string  clojure.walk  core  currentTimeMillis  data  else
generate-string  java.lang.Boolean  java.lang.Double  java.lang.Float
java.lang.Integer  java.lang.Long  java.lang.Math  java.lang.String
java.lang.System  java.time.Duration  java.time.Instant  java.time.LocalDate
java.time.Period  java.util.Date  json  p1 … p20  parse  parse-lines
parse-string  regex  string  strs  text  tool  while
```

The count is specific to that probe shape; other positions (`def` constants,
public definitions, `let` bindings) exercise different insertion sites and can
surface more. `text`, `string`, `json`, `data`, `parse`, `parse-string` and
`core` are all plausible helper names in ordinary code, so this is an
everyday hazard rather than a Java-interop curiosity.

Names that are also builtins (`abs`, `ceil`, `floor`, `max`, `min`, `pow`,
`round`, `sqrt`, `format`, …) already resolve, because `Env.builtin?/1` is
consulted before the scope and a `def` that shadows a builtin is allowed.

Making these names resolve does not make special forms redefinable: the
analyzer dispatches `(while …)`, `(data/input)` and friends on the head symbol
before this check ever runs. The fix only stops a name the user *did* define
from being reported as undefined.

## Fix

Make the static scope check representation-agnostic by normalising to a single
representation, rather than adding the missing direction to the existing
two-way bridge. Strings are the right target: `undefined_vars/2` already
returns strings, and `collect_undefined_vars({:var, name}, _)` already computes
`name_str`.

In `lib/ptc_runner/lisp.ex`:

1. Add a private `put_scope/2` that inserts `to_string(name)`, and use it at
   every scope-insertion site: `{:fn, params, body}` (`:2652`),
   `{:fn, name, params, body}` (`:2657-2662`), `{:def, …}` (`:2710`),
   `{:defonce, …}` (`:2714`), `{:do, …}` (`:2727`), and `reduce_bindings/2`
   (`:2804`).
2. Normalise the caller-supplied scope once, at the `undefined_vars/2` entry
   point (`:2615`), so an external caller passing atoms still works.
3. Replace the `scope_member?(scope, name)` call with
   `MapSet.member?(scope, name_str)` and delete `scope_member?/2`, which has no
   other caller. **Keep `safe_to_existing_atom/1`** — `memory_binding?/2`
   (`lisp.ex:2222`) uses it independently.

`Env.builtin?/1` keeps receiving the raw `name`: it is documented to return
`false` for binaries precisely because interning would have produced an atom
for a builtin, and that contract is unchanged.

In `lib/ptc_runner/lisp/source_atoms.ex`, correct the "What's NOT in the table"
moduledoc section (`:38-42`). It claims `def` bindings and `fn` params stay
binary, which is false whenever the name's spelling overlaps the bounded
vocabulary — the very case this bug is about.

## Explicitly not in scope

- **Changing `priv/java_interop.exs` to use string `source_name`s.** That would
  drop `parse`/`between`/`currentTimeMillis` from the source-atoms table
  entirely, changing what `LocalDate/parse` interns to and touching Java
  dispatch. Once the resolver is representation-agnostic the atom/string
  inconsistency in that file is cosmetic. Record as a residual.
- **The other #1166 items.** Item 1 is fixed; items 3 and 4 are in
  `command_destination.ex` / `manifest_repl.ex` and share no code with this.
- **#1246** (component compile errors carrying no message on the `run`/
  `validate` path). Independent; this fix removes one instance of that
  symptom rather than the cause.

## Verification

1. **Failing test first**, in the module that owns the static check. A single
   sibling-definition case does not prove every `put_scope/2` site was
   converted, so cover each changed insertion class:

   - both directions — atom reference against string scope (`parse`) and
     string reference against atom scope;
   - `defn` params and named-`fn` recursion (`{:fn, name, params, body}`);
   - `let` and `loop` bindings (`reduce_bindings/2`);
   - `def`/`defonce` and sequential top-level definitions (`{:do, …}`);
   - names from a non-Java table source, so the fix is not read as
     Java-specific — `text` or `p1` will do.

   Keep an existing-behaviour case for a genuinely undefined name so the check
   is not simply disabled, and keep that negative control **outside `(or …)`**,
   whose bare variable references are deliberately skipped (`lisp.ex:2741`).
2. **Prelude-compiler level**: `Prelude.Compiler.compile/1` on the reported
   source must return `{:ok, _}` where it currently returns
   `{:error, %ValidationError{reason: :unbound_var}}`.
3. **End-to-end**: a workflow manifest whose component defines and calls
   `parse` must pass `mix ptc validate` and produce the right value under
   `mix ptc run` — the static check passing does not by itself prove the
   runtime resolver binds the same name.
4. **Negative control**: an actually-undefined variable must still be
   rejected, with its name in the message.
5. `mix precommit`.

## Outcome

Implemented as planned. Three deviations, all from review:

- The per-insertion-site cases had to move **out** of the prelude compiler and
  into `PtcRunner.LispTest`, driving `undefined_vars/2` on hand-built CoreAST.
  Parsing one form gives params and their references the same representation,
  and the compiler pre-seeds every namespace definition into the initial scope,
  so a source-level test cannot reach the `def`/`defonce`/`do` insertion paths
  or mix representations at all. The prelude-compiler cases remain as
  acceptance checks and are labelled as such.
- Those hand-built trees are validated with `CoreAST.validate/1` before being
  asserted on. That caught a `:keys` destructuring pattern built with map
  defaults where `core_ast.ex:447` specifies a list of pairs — an impossible
  tree the assertion had been passing on.
- `SourceAtoms`' moduledoc needed a fuller rewrite than "correct the claim":
  the section framed table membership as a property of the *binding category*
  when it is a property of the *spelling*.

Measured: 68 of the 380 table keys failed the probe before, 0 after; end-to-end
`mix ptc validate` and `mix ptc run` over a component defining and calling both
`parse` and `text`; `mix precommit` green.

### Residuals

- `priv/java_interop.exs` still mixes atom and string `source_name`s
  (`:parse` vs `"parseInt"`) with no stated rule. Harmless now that the
  resolver is representation-agnostic, but it is why `parse` was in the table
  and `parseInt` was not.
- The runtime resolver reaches the same outcome by a different route —
  `Eval.resolve_user_ns/3` and `resolve_legacy_user_ns/3` keep a two-way
  atom/binary bridge rather than normalising. Not a bug (verified end-to-end),
  but it is the same asymmetry left standing in a second place.
