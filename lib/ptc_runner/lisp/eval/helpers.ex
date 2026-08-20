defmodule PtcRunner.Lisp.Eval.Helpers do
  @moduledoc """
  Shared helper functions for Lisp evaluation.

  Provides type error formatting and type description utilities.
  """

  alias PtcRunner.Kernel.AgentConfigDiagnostic
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.LLMReplayDiagnostic
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Lisp.CoreAST
  alias PtcRunner.Lisp.Env
  alias PtcRunner.Lisp.Env.Builtin
  alias PtcRunner.Lisp.Format.SymbolRef
  alias PtcRunner.Lisp.Java.Callable, as: JavaCallable
  alias PtcRunner.Lisp.Java.Primitive, as: JavaPrimitive
  alias PtcRunner.Lisp.Java.Time.Duration, as: JavaDuration
  alias PtcRunner.Lisp.Java.Time.Instant, as: JavaInstant
  alias PtcRunner.Lisp.Java.Time.LocalDate, as: JavaLocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.SpecialBuiltin

  @stable_parallel_errors [:memory_exceeded, :timeout, :parallel_capacity_exceeded]
  @result_contract_constraints [
    :additionalProperties,
    :boolean_schema,
    :const,
    :enum,
    :format,
    :json_value,
    :maximum,
    :maxItems,
    :maxLength,
    :minimum,
    :minItems,
    :minLength,
    :required,
    :type
  ]
  @parallel_run_deadline_message "the run deadline expired during a parallel operation"
  @safe_type_names [
    "boolean",
    "function",
    "invalid Java value",
    "java.time.Duration",
    "java.time.Instant",
    "java.time.LocalDate",
    "java.util.Date",
    "keyword",
    "list",
    "map",
    "nil",
    "number",
    "set",
    "string",
    "unknown"
  ]

  @doc """
  Generates a type error tuple for FunctionClauseError in builtins.
  """
  @spec type_error_for_args(function(), [term()]) :: {:type_error, String.t(), term()}
  def type_error_for_args(fun, args) do
    fun_name = function_name(fun)

    case specific_type_error(fun_name, args) do
      {:ok, error} -> error
      :none -> generic_type_error(fun_name, args)
    end
  end

  # Specific error messages for common mistakes
  defp specific_type_error(name, [_, %MapSet{} = set])
       when name in [:take, :drop, :sort_by, :take_while, :drop_while] do
    {:ok, {:type_error, "#{name} does not support sets (sets are unordered)", set}}
  end

  defp specific_type_error(name, [%MapSet{} = set])
       when name in [:first, :last, :nth, :reverse, :distinct, :flatten, :sort] do
    {:ok, {:type_error, "#{name} does not support sets (sets are unordered)", set}}
  end

  # first/last/nth/reverse/distinct on maps - maps are unordered
  defp specific_type_error(name, [%{} = map] = args)
       when name in [:first, :last, :reverse, :distinct] and not is_struct(map) do
    {:ok,
     {:type_error,
      "#{name} does not support maps (maps are unordered). " <>
        "Use (keys m), (vals m), or (entries m) to get a sorted list", args}}
  end

  defp specific_type_error(:nth, [_n, %{} = _map] = args) do
    {:ok,
     {:type_error,
      "nth does not support maps (maps are unordered). " <>
        "Use (keys m), (vals m), or (entries m) to get a sorted list", args}}
  end

  defp specific_type_error(:update_vals, [f, m] = args) when is_function(f) and is_map(m) do
    {:ok,
     {:type_error,
      "update-vals expects (map, function) but got (function, map). " <>
        "Use -> (thread-first) instead of ->> (thread-last) with update-vals", args}}
  end

  defp specific_type_error(:update_vals, [%Builtin{} = _f, m] = args) when is_map(m) do
    {:ok,
     {:type_error,
      "update-vals expects (map, function) but got (function, map). " <>
        "Use -> (thread-first) instead of ->> (thread-last) with update-vals", args}}
  end

  # Also match builtin tuples (now passed through from closure_to_fun)
  defp specific_type_error(:update_vals, [{tag, _} = _f, m] = args)
       when tag in [:normal, :collect] and is_map(m) do
    {:ok,
     {:type_error,
      "update-vals expects (map, function) but got (function, map). " <>
        "Use -> (thread-first) instead of ->> (thread-last) with update-vals", args}}
  end

  defp specific_type_error(:update_vals, [{tag, _, _} = _f, m] = args)
       when tag in [:variadic, :variadic_nonempty, :multi_arity] and is_map(m) do
    {:ok,
     {:type_error,
      "update-vals expects (map, function) but got (function, map). " <>
        "Use -> (thread-first) instead of ->> (thread-last) with update-vals", args}}
  end

  defp specific_type_error(:sort_by, [key, coll, comp] = args)
       when (is_atom(key) or is_binary(key) or is_function(key, 1)) and is_list(coll) and
              (is_function(comp) or comp in [:asc, :desc, :>, :<]) do
    {:ok,
     {:type_error,
      "sort-by expects (key, comparator, collection) but got (key, collection, comparator). " <>
        "Try: (sort-by #{inspect(key)} #{inspect(comp)} collection)", args}}
  end

  # (get key map) / (get-in path map) — collection must come first. A keyword
  # or string first arg with a map second arg is almost always swapped.
  defp specific_type_error(name, [k, %{} = m] = args)
       when name in [:get, :get_in] and not is_struct(m) and
              (is_atom(k) or is_binary(k) or is_list(k) or
                 is_struct(k, PtcRunner.Lisp.Keyword)) do
    {:ok,
     {:type_error,
      "#{display_name(name)} expects the collection first, e.g. (#{display_name(name)} map key) — " <>
        "got (#{describe_type(k)}, map), arguments appear to be swapped", args}}
  end

  defp specific_type_error(_name, _args), do: :none

  defp display_name(:get_in), do: "get-in"
  defp display_name(name), do: to_string(name)

  defp generic_type_error(fun_name, args) do
    type_descriptions = Enum.map(args, &describe_type/1)

    {:type_error, "#{fun_name}: invalid argument types: #{Enum.join(type_descriptions, ", ")}",
     args}
  end

  @doc """
  Describes the type of a value for error messages.
  """
  @spec describe_type(term()) :: String.t()
  def describe_type(nil), do: "nil"
  def describe_type(%Builtin{}), do: "function"

  def describe_type(%JavaCallable{} = callable),
    do: if(JavaCallable.valid?(callable), do: "function", else: "invalid Java value")

  def describe_type(%JavaPrimitive{} = primitive),
    do: if(JavaPrimitive.valid?(primitive), do: "number", else: "invalid Java value")

  def describe_type(%JavaLocalDate{} = value),
    do: java_object_description(JavaLocalDate, value, "java.time.LocalDate")

  def describe_type(%JavaInstant{} = value),
    do: java_object_description(JavaInstant, value, "java.time.Instant")

  def describe_type(%JavaDuration{} = value),
    do: java_object_description(JavaDuration, value, "java.time.Duration")

  def describe_type(%JavaDate{} = value),
    do: java_object_description(JavaDate, value, "java.util.Date")

  def describe_type(%MapSet{}), do: "set"
  def describe_type(%LispKeyword{}), do: "keyword"
  def describe_type(x) when is_list(x), do: "list"
  def describe_type(x) when is_map(x), do: "map"
  def describe_type(x) when is_binary(x), do: "string"
  def describe_type(x) when is_number(x), do: "number"
  def describe_type(x) when is_boolean(x), do: "boolean"
  def describe_type(x) when is_atom(x), do: "keyword"
  def describe_type(x) when is_function(x), do: "function"
  # Internal builtin-binding tuples (e.g. `{:normal, &fun/2}`) — these reach
  # error formatting when a builtin is used as a value, e.g. `(first filter)`.
  # Surface them as "function" rather than the leaky "unknown".
  def describe_type({tag, _}) when tag in [:normal, :collect], do: "function"

  def describe_type({:special, name}) do
    if SpecialBuiltin.callable?(name), do: "function", else: "unknown"
  end

  def describe_type({:juxt_fn, fns}) when is_list(fns), do: "function"
  def describe_type({tag, _}) when tag in [:complement_fn, :constantly_fn], do: "function"

  def describe_type({tag, fns}) when tag in [:comp_fn, :every_pred_fn, :some_fn] and is_list(fns),
    do: "function"

  def describe_type({:partial_fn, _f, fixed}) when is_list(fixed), do: "function"
  def describe_type({:fnil_fn, _f, _default}), do: "function"

  def describe_type({tag, _, _}) when tag in [:variadic, :variadic_nonempty, :multi_arity],
    do: "function"

  def describe_type(_), do: "unknown"

  # Special forms that require parentheses - bare symbols will fail with :unbound_var
  @special_forms MapSet.new([
                   :return,
                   :fail,
                   :let,
                   :if,
                   :fn,
                   :when,
                   :"if-let",
                   :"when-let",
                   :"if-some",
                   :"when-some",
                   :"when-first",
                   :cond,
                   :case,
                   :condp,
                   :do,
                   :and,
                   :or,
                   :not,
                   :->,
                   :"->>",
                   :"as->",
                   :"cond->",
                   :"cond->>",
                   :"some->",
                   :"some->>"
                 ])

  # Common Clojure/Java functions that don't exist in PTC-Lisp, with alternatives
  @clojure_alternatives %{
    "format" => "use str and arithmetic, e.g. (str (* 100.0 (/ a b)) \"%\")",
    "re-find" => "use grep for line matching, or (re-pattern \"...\") with re-find",
    "re-seq" => "use (re-seq (re-pattern \"...\") text) — requires compiled regex",
    "printf" => "use println with str",
    "spit" => "not available — no file I/O",
    "slurp" => "not available — no file I/O",
    "require" => "not available — no namespace loading",
    "import" => "not available — no Java interop"
  }

  # Definition heads the prelude compiler understands but the analyzer does not.
  # In dynamic source the whole form parses as a call to an undefined head, so
  # the head is the cause and every name the form would have bound is a
  # consequence — say which is which.
  @definition_only_forms %{
    "defn-" =>
      "'defn-' defines a private helper in component source only; use defn in dynamic source",
    "ns" =>
      "'ns' declares a component namespace in component source only; it is not a dynamic form"
  }

  @doc """
  Returns the definition-only-form hint for the first matching name, or `nil`.

  Accepts one name or a list of them, and answers `nil` for anything else so
  callers projecting untrusted diagnostic detail need no shape check first.
  """
  @spec definition_only_hint(term()) :: String.t() | nil
  def definition_only_hint(names) when is_list(names),
    do: Enum.find_value(names, &definition_only_hint/1)

  def definition_only_hint(name) when is_binary(name) or is_atom(name),
    do: Map.get(@definition_only_forms, to_string(name))

  def definition_only_hint(_names), do: nil

  @doc """
  Formats closure errors with helpful messages.
  """
  @spec format_closure_error(term()) :: String.t()
  def format_closure_error({:unbound_var, name}) do
    var_str = to_string(name)

    cond do
      # Check if the name is a definition head that only component source has
      hint = definition_only_hint(var_str) ->
        "Undefined variable: #{var_str}. Hint: #{hint}"

      # Check if it's a special form used without parentheses
      MapSet.member?(@special_forms, name) ->
        "Undefined variable: #{var_str}. Hint: '#{var_str}' is a special form, use (#{var_str} ...) with parentheses"

      # Check for common Clojure/Java functions not in PTC-Lisp
      alt = Map.get(@clojure_alternatives, var_str) ->
        "Undefined variable: #{var_str}. Not available in PTC-Lisp — #{alt}"

      # Check for common underscore/hyphen confusion
      String.contains?(var_str, "_") ->
        suggested = String.replace(var_str, "_", "-")
        "Undefined variable: #{var_str}. Hint: Use hyphens not underscores (try: #{suggested})"

      # Try to find similar builtin names
      suggestion = find_similar_builtin(name) ->
        "Undefined variable: #{var_str}. Did you mean: #{suggestion}"

      true ->
        "Undefined variable: #{var_str}"
    end
  end

  def format_closure_error(reason), do: "closure error: #{inspect(reason)}"

  @doc false
  @spec sanitize_private_error(term()) :: term()
  def sanitize_private_error({:type_error, _message, {:safe_diagnostic, _diagnostic}} = reason),
    do: sanitize_private_error(reason, nil)

  # The run-deadline variant of the timeout message is itself a stable
  # constant, so preserving it leaks nothing while keeping the binding limit
  # attributable at the Kernel boundary.
  def sanitize_private_error({:timeout, @parallel_run_deadline_message, nil}),
    do: {:timeout, @parallel_run_deadline_message, nil}

  def sanitize_private_error({reason, _message, nil}) when reason in @stable_parallel_errors,
    do: {reason, stable_parallel_error_message(reason), nil}

  def sanitize_private_error({:pmap_error, _message, taxonomy}) when is_map(taxonomy),
    do: sanitize_private_parallel_failure(:pmap_error, nil, taxonomy)

  def sanitize_private_error({:pcalls_error, index, _message, taxonomy})
      when is_integer(index) and is_map(taxonomy),
      do: sanitize_private_parallel_failure(:pcalls_error, index, taxonomy)

  def sanitize_private_error(
        {:runtime_limit_exceeded, _message,
         %{limit: :subordinate_evaluations, limit_value: limit}} = reason
      ) do
    with {:ok, row} <- LimitCatalog.fetch(:subordinate_evaluations),
         true <- LimitCatalog.valid_value?(row, limit) do
      reason
    else
      _invalid -> {:private_prelude_error, "private prelude evaluation failed"}
    end
  end

  def sanitize_private_error(
        {:runtime_limit_exceeded, _message,
         %{limit: :agent_turns, limit_value: limit, limit_reason: limit_reason}} = reason
      )
      when limit in 1..128 do
    if RuntimeLimitDiagnostic.agent_turns_reason?(limit_reason),
      do: reason,
      else: {:private_prelude_error, "private prelude evaluation failed"}
  end

  def sanitize_private_error(
        {:runtime_limit_exceeded, _message, %{limit: :max_transcript_chars, limit_value: limit}} =
          reason
      )
      when limit in 1..1_000_000,
      do: reason

  def sanitize_private_error(
        {:llm_provider_failed, _message, %{failure_kind: "llm-provider-error"} = details}
      ) do
    case SafeMetadata.retain_llm_provider_failure_fields(details) do
      retained when map_size(retained) == 2 ->
        details =
          retained
          |> Map.put(:failure_kind, "llm-provider-error")
          |> Map.merge(LLMReplayDiagnostic.retain_candidate_metadata(details))

        {:llm_provider_failed, "LLM provider request failed", details}

      %{} ->
        {:private_prelude_error, "private prelude evaluation failed"}
    end
  end

  def sanitize_private_error(
        {:result_contract_failed, message,
         %{
           agent_turns: turns,
           constraint: constraint,
           contract_authority: authority,
           violations: violations
         } = details}
      )
      when is_binary(message) and turns in 1..128 and
             constraint in @result_contract_constraints and is_map(authority) and
             is_list(violations) do
    source = Map.get(details, :contract_source)

    if (is_nil(source) or is_binary(source)) and
         result_contract_violations?(violations, constraint) do
      retained =
        details
        |> Map.take([
          :agent_turns,
          :constraint,
          :contract_authority,
          :contract_source,
          :violations
        ])

      {:result_contract_failed, message, retained}
    else
      {:private_prelude_error, "private prelude evaluation failed"}
    end
  end

  def sanitize_private_error({:invalid_agent_config, message, details} = reason)
      when is_binary(message) do
    if AgentConfigDiagnostic.valid_error?(message, details),
      do: reason,
      else: {:private_prelude_error, "private prelude evaluation failed"}
  end

  def sanitize_private_error({:loop_limit_exceeded, limit}) when is_integer(limit),
    do: {:loop_limit_exceeded, limit}

  def sanitize_private_error({:tool_call_limit_exceeded, limit})
      when is_integer(limit) or is_nil(limit),
      do: {:tool_call_limit_exceeded, limit}

  def sanitize_private_error({:type_error, _message, _callback_args}),
    do: {:type_error, "prelude function failed with a type error", nil}

  def sanitize_private_error({:destructure_error, _message}),
    do: {:destructure_error, "private prelude evaluation failed during destructuring"}

  def sanitize_private_error({:not_callable, _private_value}),
    do: {:not_callable, :private_prelude_value}

  def sanitize_private_error({:invalid_map_call, _private_map, _private_args}),
    do: {:invalid_map_call, :private_prelude_value, []}

  def sanitize_private_error({:invalid_keyword_call, _private_key, _private_args}),
    do: {:invalid_keyword_call, :private_prelude_value, []}

  def sanitize_private_error({:invalid_tool_args, _private_message}),
    do: {:invalid_tool_args, "private prelude tool call received invalid arguments"}

  def sanitize_private_error({:tool_error, name, _private_reason}) when is_binary(name),
    do: {:tool_error, name, "private prelude tool execution failed"}

  def sanitize_private_error({:private_tool_unauthorized, name, authorization})
      when is_binary(name) and is_map(authorization),
      do: {:private_tool_unauthorized, name, authorization}

  def sanitize_private_error({:private_tool_args_error, name, details}) when is_binary(name),
    do: {:private_tool_args_error, name, sanitize_private_validation_details(details)}

  def sanitize_private_error({:prelude_contract_error, message, details})
      when is_binary(message) and is_map(details),
      do: {:prelude_contract_error, message, details}

  def sanitize_private_error({:__ptc_hof_callback_error__, _private_message}),
    do: {:__ptc_hof_callback_error__, "private prelude callback failed"}

  def sanitize_private_error({:private_prelude_error, _private_message}),
    do: {:private_prelude_error, "private prelude evaluation failed"}

  def sanitize_private_error(_reason),
    do: {:private_prelude_error, "private prelude evaluation failed"}

  defp result_contract_violations?([], :json_value), do: true

  defp result_contract_violations?([%{kind: constraint, path: path} = violation], constraint)
       when is_map(path) do
    Enum.all?(Map.keys(violation), &(&1 in [:kind, :path, :missing_required]))
  end

  defp result_contract_violations?(_violations, _constraint), do: false

  @doc false
  @spec sanitize_private_error(term(), term()) :: term()
  def sanitize_private_error(
        {:type_error, _message,
         {:safe_diagnostic,
          %{
            operator: operator,
            expected: "number",
            actual_types: [left_type, right_type]
          } = diagnostic}},
        origin
      )
      when map_size(diagnostic) == 3 and operator in ["<", "<=", ">", ">="] and
             left_type in @safe_type_names and right_type in @safe_type_names do
    message =
      diagnostic_prefix(origin) <>
        "#{operator}: expected number arguments, got #{left_type}, #{right_type}"

    {:type_error, message, {:safe_diagnostic, diagnostic}}
  end

  def sanitize_private_error({:type_error, _message, _private_args}, origin),
    do:
      {:type_error, diagnostic_prefix(origin) <> "prelude function failed with a type error", nil}

  def sanitize_private_error(reason, _origin), do: sanitize_private_error(reason)

  defp diagnostic_prefix(%{ref: ref}) when is_binary(ref) do
    if CoreAST.valid_prelude_ref?(ref), do: ref <> ": ", else: ""
  end

  defp diagnostic_prefix(%{namespace: namespace}) when is_binary(namespace) do
    if SymbolRef.valid_name?(namespace), do: namespace <> ": ", else: ""
  end

  defp diagnostic_prefix(_origin), do: ""

  @doc false
  @spec parallel_timeout_message() :: String.t()
  def parallel_timeout_message, do: "the parallel operation exceeded its deadline"

  @doc false
  @spec parallel_run_deadline_message() :: String.t()
  def parallel_run_deadline_message, do: @parallel_run_deadline_message

  defp stable_parallel_error_message(:memory_exceeded),
    do: "a parallel worker exceeded its per-worker heap cap"

  defp stable_parallel_error_message(:timeout), do: parallel_timeout_message()

  defp stable_parallel_error_message(:parallel_capacity_exceeded),
    do: "the parallel worker budget is exhausted; reduce nesting or collection size"

  defp sanitize_private_parallel_failure(reason, index, taxonomy) do
    retained = LLMReplayDiagnostic.retain_parallel_failure_metadata(taxonomy)

    case retained do
      # Taxonomy, provider-failure pair, replay hash, and named-quota triple.
      retained when map_size(retained) in 1..7 ->
        message = "fail called inside #{if(reason == :pmap_error, do: "pmap", else: "pcalls")}"

        case reason do
          :pmap_error -> {:pmap_error, message, retained}
          :pcalls_error -> {:pcalls_error, index, message, retained}
        end

      _invalid_or_empty ->
        {:private_prelude_error, "private prelude evaluation failed"}
    end
  end

  defp sanitize_private_validation_details(details) when is_binary(details) do
    details
    |> String.split("; ")
    |> Enum.map_join("; ", fn detail ->
      message =
        case String.split(detail, ": ", parts: 2) do
          [_private_path, safe_message] -> safe_message
          [_message] -> "arguments did not match the private tool signature"
        end

      "private validation: #{message}"
    end)
  end

  defp sanitize_private_validation_details(_details),
    do: "private validation: arguments did not match the private tool signature"

  # Find a similar builtin name using Jaro distance + heuristics
  defp find_similar_builtin(name) do
    name_str = to_string(name)
    builtins = Env.initial() |> Map.keys() |> Enum.map(&to_string/1)

    # Score each builtin: higher is better
    scored =
      builtins
      |> Enum.map(fn builtin ->
        jaro = String.jaro_distance(name_str, builtin)
        # Bonus for same sorted characters (catches transpositions like "mpa" -> "map")
        same_chars_bonus = if sorted_chars(name_str) == sorted_chars(builtin), do: 0.3, else: 0
        # Bonus for similar length (penalize long suggestions for short input)
        len_diff = abs(String.length(name_str) - String.length(builtin))
        len_penalty = len_diff * 0.05
        score = jaro + same_chars_bonus - len_penalty
        {builtin, score, jaro}
      end)
      |> Enum.filter(fn {_builtin, score, jaro} -> score > 0.8 or jaro > 0.85 end)
      |> Enum.max_by(fn {_builtin, score, _jaro} -> score end, fn -> nil end)

    case scored do
      {builtin, _score, _jaro} -> builtin
      nil -> nil
    end
  end

  defp sorted_chars(str) do
    str |> String.graphemes() |> Enum.sort()
  end

  defp java_object_description(module, value, label) do
    if module.valid?(value), do: label, else: "invalid Java value"
  end

  # Extract function name from function reference
  defp function_name(fun) when is_function(fun) do
    case Function.info(fun, :name) do
      {:name, name} -> name
      _ -> :unknown
    end
  end
end
