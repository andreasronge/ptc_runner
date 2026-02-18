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

  @type literal ::
          nil
          | boolean()
          | number()
          | {:string, String.t()}
          | {:keyword, atom()}

  @type fn_params :: [pattern()] | {:variadic, [pattern()], pattern()}

  @type t ::
          literal
          # Collections
          | {:vector, [t()]}
          | {:map, [{t(), t()}]}
          | {:set, [t()]}
          # Variables and namespace access
          | {:var, atom()}
          | {:data, atom()}
          # Function call: f(args...)
          | {:call, t(), [t()]}
          # Let bindings: (let [p1 v1 p2 v2 ...] body)
          | {:let, [binding()], t()}
          # Conditionals
          | {:if, t(), t(), t()}
          # Anonymous function
          | {:fn, fn_params(), t()}
          # Sequential evaluation (special forms, not calls)
          | {:do, [t()]}
          # Short-circuit logic (special forms, not calls)
          | {:and, [t()]}
          | {:or, [t()]}
          # Predicates
          | {:where, field_path(), where_op(), t() | nil}
          | {:pred_combinator, :all_of | :any_of | :none_of, [t()]}
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
          | {:tool_call, atom(), [t()]}
          # Define binding in user namespace: (def name value) with optional metadata
          | {:def, atom(), t(), map()}
          # Idempotent define: (defonce name value) — no-op if already bound
          | {:defonce, atom(), t(), map()}
          # Tail recursion: loop and recur
          | {:loop, [binding()], t()}
          | {:recur, [t()]}

  @type binding :: {:binding, pattern(), t()}

  @type pattern ::
          {:var, atom()}
          | {:destructure, {:keys, [atom()], keyword()}}
          | {:destructure, {:map, [atom()], [{atom(), atom()}], keyword()}}
          | {:destructure, {:as, atom(), pattern()}}
          | {:destructure, {:seq, [pattern()]}}
          # Rest pattern: [a b & rest] binds rest to remaining elements
          | {:destructure, {:seq_rest, [pattern()], pattern()}}

  @type field_path :: {:field, [field_segment()]}
  @type field_segment :: {:keyword, atom()} | {:string, String.t()}

  @type where_op ::
          :eq
          | :not_eq
          | :gt
          | :lt
          | :gte
          | :lte
          | :includes
          | :in
          | :truthy
end
