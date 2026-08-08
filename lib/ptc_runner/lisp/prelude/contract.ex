defmodule PtcRunner.Lisp.Prelude.Contract do
  @moduledoc false

  alias PtcRunner.Lisp.Eval.Abort
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Signature.Validator
  alias PtcRunner.Utf8

  @max_errors 16
  @max_message_bytes 4_096
  @max_path_segments 32
  @max_path_segment_bytes 256

  @spec validate_input!(map(), [term()], EvalContext.t()) :: :ok
  def validate_input!(metadata, args, %EvalContext{} = eval_ctx) do
    case contract(metadata) do
      %{signature: {:signature, params, _return_type}} = contract ->
        input = params |> Enum.map(&elem(&1, 0)) |> Enum.zip(args) |> Map.new()

        case Validator.validate(input, {:map, params},
               keyword_representation: :internal,
               max_errors: @max_errors
             ) do
          :ok -> :ok
          {:error, errors} -> raise_contract(contract, :input, errors, eval_ctx)
        end

      nil ->
        :ok
    end
  end

  @spec validate_output!(map(), term(), EvalContext.t()) :: :ok
  def validate_output!(metadata, value, %EvalContext{} = eval_ctx) do
    case contract(metadata) do
      %{signature: signature} = contract ->
        {:signature, _params, return_type} = signature

        case Validator.validate(value, return_type,
               keyword_representation: :internal,
               max_errors: @max_errors
             ) do
          :ok -> :ok
          {:error, errors} -> raise_contract(contract, :output, errors, eval_ctx)
        end

      nil ->
        :ok
    end
  end

  defp contract(%{prelude_contract: %{ref: ref, signature: signature, display: display}})
       when is_binary(ref) and is_tuple(signature) and is_binary(display) do
    %{ref: ref, signature: signature, display: display}
  end

  defp contract(_metadata), do: nil

  @spec raise_contract(map(), atom(), [map()], EvalContext.t()) :: no_return()
  defp raise_contract(contract, phase, errors, eval_ctx) do
    errors = errors |> Enum.take(@max_errors) |> Enum.map(&public_error/1)
    first = List.first(errors) || %{path: [], message: "contract validation failed"}
    path = first.path
    location = if path == [], do: "", else: " " <> Enum.join(path, ".")

    message =
      "#{contract.ref} #{phase}#{location}: #{first.message}"
      |> truncate(@max_message_bytes)

    details = %{
      ref: contract.ref,
      phase: phase,
      path: path,
      expected: truncate(contract.display, @max_message_bytes),
      errors: errors,
      capability_activity?: EvalContext.tool_activity?(eval_ctx)
    }

    reason = {:prelude_contract_error, message, details}
    Abort.error!(reason, eval_ctx)
  end

  defp public_error(%{path: path, message: message}) when is_list(path) and is_binary(message) do
    %{
      path: path |> Enum.take(@max_path_segments) |> Enum.map(&public_path_segment/1),
      message: truncate(message, 512)
    }
  end

  defp public_path_segment(segment) when is_binary(segment),
    do: truncate(segment, @max_path_segment_bytes)

  defp public_path_segment(segment) when is_integer(segment), do: segment
  defp public_path_segment(segment), do: segment |> inspect(limit: 3) |> truncate(256)

  defp truncate(value, max_bytes), do: Utf8.truncate(value, max_bytes)
end
