defmodule PtcRunner.Lisp.CoreAST do
  @moduledoc """
  Core, validated AST for PTC-Lisp.

  This module defines the type specifications for the intermediate
  representation that the analyzer produces. The interpreter evaluates
  CoreAST to produce results.

  ## Pipeline

  ```
  source → Parser → RawAST → Analyze → CoreAST → Eval → result
  ```
  """

  @type name :: atom() | String.t()

  @type literal ::
          nil
          | boolean()
          | number()
          | {:string, String.t()}
          | {:keyword, name()}
          | {:symbol_ref, String.t()}
          | {:repl_discovery, atom(), [t()]}

  @type fn_params :: [pattern()] | {:variadic, [pattern()], pattern()}

  @type t ::
          literal
          # Collections
          | {:vector, [t()]}
          | {:map, [{t(), t()}]}
          | {:set, [t()]}
          # Variables and namespace access
          | {:var, name()}
          | {:data, name()}
          # Function call: f(args...)
          | {:call, t(), [t()]}
          # Let bindings: (let [p1 v1 p2 v2 ...] body)
          | {:let, [binding()], t()}
          # Conditionals
          | {:if, t(), t(), t()}
          # Anonymous function (optionally named for self-recursion)
          | {:fn, fn_params(), t()}
          | {:fn, name(), fn_params(), t()}
          # Sequential evaluation (special forms, not calls)
          | {:do, [t()]}
          # Short-circuit logic (special forms, not calls)
          | {:and, [t()]}
          | {:or, [t()]}
          # Control flow signals
          | {:return, t()}
          | {:fail, t()}
          # Journaled task: (task "id" expr) or (task id-expr expr)
          | {:task, String.t(), t()}
          | {:task_dynamic, t(), t()}
          # Semantic progress: (step-done id summary), (task-reset id)
          | {:step_done, t(), t()}
          | {:task_reset, t()}
          # Tool invocation via tool/ namespace: (tool/name args...)
          | {:tool_call, name(), [t()]}
          # Public prelude export reference / call (Capability Prelude V1).
          # `ref` is the host-boundary string ref, e.g. "crm/get-user". The
          # evaluator resolves it from the attached prelude's export table and
          # invokes the captured closure against the captured private prelude
          # env so the export can call its private sibling helpers.
          | {:prelude_ref, String.t()}
          | {:prelude_call, String.t(), [t()]}
          # Define binding in user namespace: (def name value) with optional metadata
          | {:def, name(), t(), map()}
          # Idempotent define: (defonce name value) — no-op if already bound
          | {:defonce, name(), t(), map()}
          # Tail recursion: loop and recur
          | {:loop, [binding()], t()}
          | {:recur, [t()]}

  @type binding :: {:binding, pattern(), t()}

  @type pattern ::
          {:var, name()}
          | {:destructure, {:keys, [name()], keyword()}}
          | {:destructure, {:map, [name()], [{pattern(), term()}], keyword()}}
          | {:destructure, {:as, name(), pattern()}}
          | {:destructure, {:seq, [pattern()]}}
          # Rest pattern: [a b & rest] binds rest to remaining elements
          | {:destructure, {:seq_rest, [pattern()], pattern()}}
end
