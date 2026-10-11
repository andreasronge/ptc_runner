defmodule PtcRunner.Lisp.ErrorFormat do
  @moduledoc false

  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.HostErrorPolicy

  alias PtcRunner.Lisp.EvaluatorError
  alias PtcRunner.Lisp.Java.Surface, as: JavaSurface
  alias PtcRunner.Lisp.UntrustedRenderer

  def error_details({:pmap_error, _message, taxonomy}, policy),
    do: HostErrorPolicy.project_failure_metadata(policy, taxonomy, :retain)

  def error_details({:pcalls_error, _index, _message, taxonomy}, policy),
    do: HostErrorPolicy.project_failure_metadata(policy, taxonomy, :retain)

  def error_details(reason, _policy), do: error_details(reason)

  def error_details({:arithmetic_error, token})
      when token in [:division_by_zero, :integer_overflow, :bad_argument],
      do: %{token: token}

  def error_details({:arity_error, details}) when is_map(details), do: details

  def error_details({:type_error, _message, {:safe_diagnostic, diagnostic}})
      when is_map(diagnostic),
      do: %{safe_diagnostic: diagnostic}

  def error_details({:invalid_tool_args, _message, {:safe_diagnostic, diagnostic}})
      when is_map(diagnostic),
      do: %{safe_diagnostic: diagnostic}

  def error_details({:not_callable, {:data_ref, symbol}}) when is_binary(symbol),
    do: %{name: symbol}

  def error_details({:not_callable, details}) when is_map(details), do: details

  def error_details({:loop_limit_exceeded, n}) when is_integer(n), do: %{limit: n}

  def error_details({:prelude_contract_error, _message, details}) when is_map(details),
    do: details

  def error_details({:pmap_error, _message, taxonomy}) when is_map(taxonomy),
    do: retain_parallel_failure_metadata(taxonomy)

  def error_details({:pcalls_error, _index, _message, taxonomy}) when is_map(taxonomy),
    do: retain_parallel_failure_metadata(taxonomy)

  def error_details({:runtime_limit_exceeded, _message, details}) when is_map(details),
    do: details

  def error_details({:model_output_truncated, _message, details}) when is_map(details),
    do: details

  def error_details({:invalid_agent_config, _message, details}) when is_map(details),
    do: details

  def error_details({:result_contract_failed, _message, details}) when is_map(details),
    do: details

  def error_details({:phase_return_contract_failed, _message, details}) when is_map(details),
    do: details

  def error_details({:llm_provider_failed, _message, details}) when is_map(details),
    do: details

  def error_details({category, _message, details})
      when category in [
             :unsupported_java_class,
             :unsupported_java_member,
             :java_arity_error,
             :java_type_error,
             :java_domain_error,
             :invalid_java_string,
             :java_handler_contract_error
           ] and is_map(details),
      do: details

  def error_details(_reason), do: %{}

  defp retain_parallel_failure_metadata(metadata) do
    HostErrorPolicy.project_failure_metadata(nil, metadata, :retain)
  end

  def format_error({:parse_error, msg}), do: "Parse error: #{msg}"
  def format_error({:analysis_error, msg}), do: "Analysis error: #{msg}"
  def format_error({:eval_error, msg}), do: "Eval error: #{msg}"

  def format_error({:invalid_placeholder, name}),
    do:
      "Analysis error: placeholder '#{name}' can only be used inside #() anonymous function syntax"

  def format_error({:timeout, ms}), do: "Timeout: execution exceeded #{ms}ms limit"

  def format_error({:memory_exceeded, info}),
    do: "Memory exceeded: #{memory_exceeded_message(info)}"

  # Normal REPL diagnostics intentionally retain useful evaluator detail;
  # command-envelope evidence uses the fixed public-safe renderer instead.
  def format_error({:type_error, message, _details}) when is_binary(message),
    do: "type_error: #{strip_typed_prefix(message, :type_error)}"

  def format_error({category, message, details})
      when category in [
             :unsupported_java_class,
             :unsupported_java_member,
             :java_arity_error,
             :java_type_error,
             :java_domain_error,
             :invalid_java_string,
             :java_handler_contract_error
           ] and is_binary(message) and is_map(details) do
    catalog_message(category, details)
  end

  # Handle Analyze errors: {:invalid_arity, atom, message}
  def format_error({:invalid_arity, _atom, msg}) when is_binary(msg), do: "Analysis error: #{msg}"

  def format_error({:unsupported_java_member, namespace, member}),
    do: unsupported_java_member_message(namespace, member)

  def format_error({:unsupported_java_class, class}),
    do:
      "Analysis error: unsupported Java class #{class}. Admitted Java classes: " <>
        Enum.join(admitted_java_class_names(), ", ")

  def format_error({:java_arity_error, reference_id, details}),
    do: java_arity_error_message(reference_id, details)

  # Handle Eval errors with specific types
  def format_error({:unbound_var, name}) do
    msg = Helpers.format_closure_error({:unbound_var, name})
    # Lowercase first letter to match existing style
    <<first::utf8, rest::binary>> = msg
    <<String.downcase(<<first::utf8>>)::binary, rest::binary>>
  end

  def format_error({:not_callable, {:data_ref, symbol}}) when is_binary(symbol),
    do: "not callable: #{symbol}"

  def format_error({:not_callable, details}) when is_map(details) do
    catalog_message(:not_callable, details)
  end

  def format_error({:not_callable, _value}) do
    catalog_message(:not_callable, %{})
  end

  def format_error({:arity_error, details}) when is_map(details) do
    catalog_message(:arity_error, details)
  end

  def format_error({:arity_error, msg}) when is_binary(msg), do: "arity error: #{msg}"

  def format_error({:arithmetic_error, token})
      when token in [:division_by_zero, :integer_overflow, :bad_argument] do
    catalog_message(:arithmetic_error, %{token: token})
  end

  def format_error({:arithmetic_error, msg}) when is_binary(msg) do
    token =
      cond do
        msg == "division by zero" or String.contains?(msg, "division by zero") ->
          :division_by_zero

        msg == "integer overflow" or String.contains?(msg, "integer overflow") ->
          :integer_overflow

        true ->
          :bad_argument
      end

    format_error({:arithmetic_error, token})
  end

  # Issue #878: dedicated formatter for unsupported interop methods.
  # Avoids the `:unbound_var` path which would treat the message as a
  # variable name and append an irrelevant hyphen-suggestion hint.
  def format_error({:unsupported_method, name, available}) do
    "Unsupported method '#{name}'. Supported interop methods: #{available}. Use (.method obj) syntax."
  end

  # Issue #884/#1710: friendly message for an opt-in loop iteration cap (DIV-01).
  # Without this clause, the raw Elixir tuple {:loop_limit_exceeded, n}
  # leaks to the LLM via the generic inspect-based fallback.
  def format_error({:loop_limit_exceeded, n}) do
    catalog_message(:loop_limit_exceeded, %{limit: n})
  end

  def format_error({:inspect_only_unavailable, _details}) do
    catalog_message(:inspect_only_unavailable, %{})
  end

  # Handle tool errors
  def format_error({:unknown_tool, name, []}), do: "Unknown tool: #{name}. No tools available."

  def format_error({:unknown_tool, name, available}),
    do: "Unknown tool: #{name}. Available tools: #{Enum.join(available, ", ")}"

  def format_error({:private_tool_unauthorized, name, %{origin: nil}}),
    do: "Private tool '#{name}' cannot be called directly"

  def format_error({:private_tool_unauthorized, name, %{origin: origin, allowed_tools: allowed}}),
    do:
      "Private tool '#{name}' is not authorized for prelude export #{origin}; " <>
        "declared private tools: #{Enum.join(allowed, ", ")}"

  def format_error({:private_tool_args_error, name, details}),
    do: "Private tool '#{name}' arguments failed validation: #{details}"

  def format_error({:transitive_call_unauthorized, ref, namespace, []}) do
    "Prelude namespace '#{namespace}' is attached only as a transitive dependency; " <>
      "attach it directly to use #{ref}."
  end

  def format_error({:transitive_call_unauthorized, ref, namespace, requirers}) do
    pulled_by = Enum.map_join(requirers, ", ", &"`#{&1}`")

    "Prelude namespace '#{namespace}' is a transitive dependency of #{pulled_by}; " <>
      "attach it directly to use #{ref}."
  end

  def format_error({:grant_filtered_prelude_export, ref, reason}) do
    "#{ref} is public in an attached prelude but was removed from this session by " <>
      "the environment grant (#{grant_filter_reason(reason)})."
  end

  def format_error({:runtime_error, msg}), do: "Runtime error: #{msg}"

  def format_error({:pmap_error, msg, _taxonomy}) when is_binary(msg),
    do: format_error({:pmap_error, msg})

  def format_error({:pcalls_error, index, msg, _taxonomy})
      when is_integer(index) and is_binary(msg),
      do: format_error({:pcalls_error, index, msg})

  def format_error({:tool_error, name, reason}),
    do: UntrustedRenderer.tool_failure(name, reason)

  # Handle other 3-tuple error formats from Eval: {type, message, data}
  def format_error({type, msg, _}) when is_atom(type) and is_binary(msg),
    do: "#{type}: #{strip_typed_prefix(msg, type)}"

  def format_error({type, msg}) when is_atom(type) and is_binary(msg),
    do: "#{type}: #{strip_typed_prefix(msg, type)}"

  def format_error(other), do: "Error: #{inspect(other, limit: 5)}"

  defp catalog_message(reason, details) do
    case EvaluatorError.lisp_message(reason, details) do
      {:ok, message} -> message
      :error -> "Evaluator error: #{reason}"
    end
  end

  defp strip_typed_prefix(message, type) when is_atom(type) and is_binary(message) do
    String.replace_prefix(message, Atom.to_string(type) <> ": ", "")
  end

  defp grant_filter_reason(:ptc_tool_denied), do: "ptc_tool_denied"
  defp grant_filter_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp grant_filter_reason(_reason), do: "grant_filtered"

  # Human-readable kill message from `PtcRunner.Lisp.Sandbox.memory_exceeded_info/0`
  # diagnostics (setup-phase kills are a grant problem, not a program
  # problem) or the integer byte limit reported by `Sandbox.run_bounded/2`.
  def memory_exceeded_message(%{phase: :setup} = info) do
    "killed during environment setup: granted context/memory/tools exceeded " <>
      "the #{info.limit_bytes}-byte setup ceiling (raise :setup_max_heap or shrink the grant)"
  end

  def memory_exceeded_message(%{phase: :eval}) do
    "heap limit exceeded: program exceeded its evaluation heap budget"
  end

  def memory_exceeded_message(bytes) when is_integer(bytes),
    do: "heap limit #{bytes} bytes exceeded"

  # Nested pmap/pcalls worker kills surface as {:memory_exceeded, message}
  # from the eval layer — already human-readable.
  def memory_exceeded_message(message) when is_binary(message), do: message

  defp admitted_java_class_names do
    JavaSurface.references()
    |> Enum.map(& &1.class_id)
    |> Enum.uniq()
    |> Enum.flat_map(fn class_id ->
      case JavaSurface.fetch_class(class_id) do
        {:ok, %{name: name}} -> [name]
        :error -> []
      end
    end)
    |> Enum.sort()
  end

  defp java_arity_error_message(reference_id, %{expected: []}) do
    spelling = java_reference_spelling(reference_id)

    "Analysis error: #{spelling} is a Java field, not a callable; " <>
      "reference it as #{spelling} without parentheses"
  end

  defp java_arity_error_message(reference_id, details) do
    arities = details.expected |> List.wrap() |> Enum.join(", ")

    "Analysis error: #{java_reference_spelling(reference_id)} accepts arity #{arities}, " <>
      "got #{details.actual}"
  end

  defp java_reference_spelling(reference_id) do
    with :error <- java_reference_spelling_from_reference(reference_id),
         :error <- JavaSurface.member_family_source(reference_id) do
      "Java reference #{reference_id}"
    else
      {:ok, spelling} -> spelling
    end
  end

  defp java_reference_spelling_from_reference(reference_id) do
    case JavaSurface.fetch_reference(reference_id) do
      {:ok, %{spellings: [spelling | _]}} -> {:ok, spelling}
      _unspelled -> :error
    end
  end

  defp unsupported_java_member_message(namespace, member) do
    members = JavaSurface.namespace_members(namespace)
    member_labels = Enum.map(members, &"#{namespace}/#{&1}")

    suffix =
      if member_labels == [],
        do: "",
        else: " Interop functions: #{Enum.join(member_labels, ", ")}"

    "Analysis error: #{namespace}/#{member} is not available.#{suffix}"
  end
end
