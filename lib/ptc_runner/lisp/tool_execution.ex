defmodule PtcRunner.Lisp.ToolExecution do
  @moduledoc false

  alias PtcRunner.Lisp.Eval.HostContext

  alias PtcRunner.Lisp.AmbiguousArguments
  alias PtcRunner.Lisp.Signature
  alias PtcRunner.Lisp.Tool
  alias PtcRunner.Lisp.TrustedError

  def execute_tool(normalized_tools, name, args, origin, failure_token) do
    case Map.fetch(normalized_tools, name) do
      {:ok, %Tool{} = tool} ->
        with :ok <- authorize_tool_call(tool, origin, failure_token),
             :ok <- validate_private_tool_args(tool, args, failure_token) do
          execute_tool_function(tool, args, failure_token)
        end

      :error ->
        available =
          normalized_tools
          |> Enum.reject(fn {_name, tool} -> Tool.private?(tool) end)
          |> Enum.map(fn {tool_name, _tool} -> tool_name end)
          |> Enum.sort()

        tool_failure(failure_token, :unknown_tool, name, available)
    end
  end

  defp execute_tool_function(
         %Tool{name: name, argument_collisions: :reject},
         %AmbiguousArguments{},
         failure_token
       ) do
    tool_failure(failure_token, :invalid_tool_args, name, :ambiguous_arguments)
  end

  defp execute_tool_function(%Tool{name: name, function: fun}, args, failure_token) do
    case HostContext.without_context(fn -> fun.(args) end) do
      %TrustedError{reason: reason, message: message, details: details}
      when is_atom(reason) and is_binary(message) and is_map(details) ->
        tool_failure(failure_token, reason, message, details)

      {:ok, value} ->
        value

      {:error, reason} ->
        recorded_tool_failure(failure_token, name, reason)

      value ->
        value
    end
  end

  defp authorize_tool_call(%Tool{visibility: :public}, _origin, _failure_token), do: :ok

  defp authorize_tool_call(
         %Tool{
           name: name,
           visibility: :private,
           prelude_namespaces: prelude_namespaces
         },
         %{
           type: :prelude_export,
           ref: ref,
           namespace: namespace,
           tool_refs: tool_refs
         },
         failure_token
       )
       when is_list(tool_refs) do
    if name in tool_refs and authorized_prelude_namespace?(prelude_namespaces, namespace) do
      :ok
    else
      tool_failure(failure_token, :private_tool_unauthorized, name, %{
        origin: ref,
        allowed_tools: tool_refs
      })
    end
  end

  defp authorize_tool_call(
         %Tool{name: name, visibility: :private},
         _origin,
         failure_token
       ) do
    tool_failure(failure_token, :private_tool_unauthorized, name, %{origin: nil})
  end

  defp authorized_prelude_namespace?(:any, _namespace), do: true

  defp authorized_prelude_namespace?(namespaces, namespace) when is_list(namespaces),
    do: namespace in namespaces

  defp validate_private_tool_args(%Tool{visibility: :public}, _args, _failure_token), do: :ok
  defp validate_private_tool_args(%Tool{signature: nil}, _args, _failure_token), do: :ok

  defp validate_private_tool_args(
         %Tool{name: name, signature: signature},
         args,
         failure_token
       ) do
    with {:ok, parsed} <- Signature.parse(signature),
         :ok <- Signature.validate_input(parsed, args) do
      :ok
    else
      {:error, errors} when is_list(errors) ->
        tool_failure(
          failure_token,
          :private_tool_args_error,
          name,
          format_signature_errors(errors)
        )

      {:error, error} ->
        tool_failure(failure_token, :private_tool_args_error, name, error)
    end
  end

  defp format_signature_errors(errors) do
    Enum.map_join(errors, "; ", fn
      %{path: path, message: message} -> "#{Enum.join(path, ".")}: #{message}"
      other -> inspect(other)
    end)
  end

  defp tool_failure(token, reason, message, data, record? \\ false),
    do: {:__ptc_tool_failure__, token, reason, message, data, record?}

  defp recorded_tool_failure(token, name, reason) do
    {reason, child_trace_id, child_step} = tool_failure_metadata(reason)

    {:__ptc_tool_failure__, token, :tool_error, name, reason, true, child_trace_id, child_step}
  end

  defp tool_failure_metadata(%{
         __child_trace_id__: child_trace_id,
         __child_step__: child_step,
         value: reason
       }),
       do: {reason, child_trace_id, child_step}

  defp tool_failure_metadata(%{__child_trace_id__: child_trace_id, value: reason}),
    do: {reason, child_trace_id, nil}

  defp tool_failure_metadata(%{__child_step__: child_step, value: reason}),
    do: {reason, nil, child_step}

  defp tool_failure_metadata(reason), do: {reason, nil, nil}

  # Normalize tools from various formats to Tool structs
  def normalize_tools(raw_tools) do
    Enum.reduce_while(raw_tools, {:ok, %{}}, fn {name, format}, {:ok, acc} ->
      case Tool.new(name, format) do
        {:ok, tool} -> {:cont, {:ok, Map.put(acc, name, tool)}}
        {:error, reason} -> {:halt, {:error, {:invalid_tool, name, reason}}}
      end
    end)
  end
end
