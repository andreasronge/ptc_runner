# Kernel return-contract and typed-prelude spike

Date: 2026-07-11

## Goal

Prove the smallest end-to-end shape before promoting it to supported API:

1. `PtcRunner.Kernel.run/2` accepts a SubAgent-compatible, return-only
   `signature:` string.
2. A model program that calls `(return ...)` with the wrong type receives
   recoverable feedback, retains definitions from that turn, and can correct
   the return on the next turn.
3. Prelude functions may declare `{:signature "..."}` metadata and constants
   may declare `{:type "..."}` metadata; those declarations reach the
   sanitized model-visible symbol inventory.

## Spike syntax

```elixir
Kernel.run(mission, llm: llm, signature: ":int")
```

```clojure
(defn lookup
  "Look up one item."
  {:signature "(id :string) -> {id :string}"}
  [id]
  ...)

(def retry-limit
  "Maximum retries."
  {:type ":int"}
  3)
```

Only shorthand and zero-parameter kernel signatures are accepted. A kernel
signature with input parameters is rejected because mission input binding is
not defined.

## Semantics under test

- Return validation happens after the sandbox evaluates a program but before
  the kernel accepts its `return` signal.
- Invalid returns become `status: "continue"` with reason
  `return_validation_failed`; they are not terminal failures.
- Memory mutations from the invalid-return program remain committed, matching
  current SubAgent behavior.
- The rendered expected type and bounded path errors are model-visible.
- With no signature, existing kernel behavior is unchanged.
- Prelude annotations are descriptive in this spike. Function arguments,
  function results, and constant values are not yet enforced.

## Non-goals

- Static type inference or checking intermediate PTC-Lisp expressions.
- Parameterized kernel input contracts.
- Provider structured-output mode.
- Set, union, callable, recursive, or polymorphic types.
- Production schema/version compatibility decisions.
- Runtime enforcement of prelude annotations.
- Updating M2/M2b or running a comparative live experiment.

## Review questions

1. Is `signature:` the right kernel option name, or should the supported API
   use `return_signature:`?
2. Should invalid-return turns commit memory?
3. Should typed prelude metadata use strings, parsed PTC-Lisp data, or both?
4. Should prelude contracts remain descriptive or become enforced runtime
   contracts at export boundaries?
5. How much type detail belongs in the default inventory versus discovery?

## Exit criteria

- Focused integration tests demonstrate both correction and typed inventory.
- Existing no-signature tests remain green.
- The spike findings and deliberate gaps are recorded for review before any
  API documentation or stability promise.

## Spike result

Implemented on 2026-07-11 as an experimental branch-local slice.

The scripted end-to-end kernel test proved that an initial program can define
`answer` and incorrectly return a map against `signature: ":int"`; the kernel
turns that signal into bounded `return_validation_failed` feedback; the next
request sees both the expected type and persisted `answer`; and a second
program can return `answer` without recomputation and complete with `42`.

The typed-prelude test proved that a function `:signature` and constant `:type`
survive compilation into export records, become sanitized symbol facts, and
render in the model-visible inventory.

An initial implementation placed return-contract rendering in
`agent.prompt`. The full gate correctly rejected that because it changed the
frozen prompt component hash used by registered experiments. The spike now
adds the contract to the host-rendered symbol inventory instead, preserving the
compiled prompt source and its provenance hash.

Focused verification:

```console
mix test test/ptc_runner/kernel_test.exs \
  test/ptc_runner/symbol_inventory_test.exs \
  test/ptc_runner/kernel/feedback_ab_test.exs
```

Result: 88 tests and one property passed.

The implementation remains a spike. Prelude parameter names are not matched
against signature names, constant values and function calls are not
contract-checked, discovery metadata is not extended, and no supported public
API documentation has been added.

Post-spike review fixes validated `:datetime` before JSON projection,
canonicalized prelude annotation strings before inventory storage/rendering,
and synchronized the internal metadata/type documentation. M2c then exercised
the return contract in both adapters; see
`experiments/m2c-tier2-return-contracts-prereg.md` and
`reports/kernel_eval/m2c-analysis.md`.
