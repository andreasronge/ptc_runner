defmodule PtcRunner.Kernel.Action do
  @moduledoc false

  @tool_name "run_ptc_lisp"
  @max_program_bytes 64_000

  @type normalized ::
          %{
            kind: String.t(),
            program: String.t() | nil,
            reason: String.t() | nil,
            content: String.t() | nil,
            tokens: map(),
            model: String.t() | nil,
            provider: String.t() | nil,
            provider_meta: map()
          }

  @spec tool_schema() :: map()
  def tool_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => @tool_name,
        "description" =>
          "Run one PTC-Lisp program. The program must explicitly call (return ...) or (fail ...).",
        "parameters" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["program"],
          "properties" => %{
            "program" => %{
              "type" => "string",
              "description" => "PTC-Lisp source code to evaluate."
            }
          }
        }
      }
    }
  end

  @spec normalize(term(), keyword()) :: normalized()
  def normalize(response, opts \\ []) do
    max_program_bytes = Keyword.get(opts, :max_program_bytes, @max_program_bytes)
    meta = extract_meta(response)

    with {:ok, map} <- response_map(response),
         :ok <- no_disallowed_content(map),
         {:ok, [call]} <- one_tool_call(map),
         :ok <- call_name(call),
         {:ok, args} <- call_args(call),
         {:ok, program} <- program_arg(args, max_program_bytes) do
      Map.merge(meta, %{kind: "tool_call", program: program, reason: nil, content: nil})
    else
      {:error, reason} ->
        Map.merge(meta, %{
          kind: "protocol_error",
          program: nil,
          reason: to_string(reason),
          content: content_of(response)
        })
    end
  end

  defp response_map({:ok, response}), do: response_map(response)
  defp response_map(%{} = response), do: {:ok, response}
  defp response_map(text) when is_binary(text), do: {:error, :free_text_response}
  defp response_map(_), do: {:error, :invalid_response}

  defp no_disallowed_content(%{content: content}) when is_binary(content) do
    if String.trim(content) == "", do: :ok, else: {:error, :assistant_text_with_tool_call}
  end

  defp no_disallowed_content(%{"content" => content}) when is_binary(content) do
    if String.trim(content) == "", do: :ok, else: {:error, :assistant_text_with_tool_call}
  end

  defp no_disallowed_content(_), do: :ok

  defp one_tool_call(map) do
    calls = Map.get(map, :tool_calls, Map.get(map, "tool_calls"))

    case calls do
      nil -> {:error, :missing_tool_call}
      [] -> {:error, :missing_tool_call}
      [_] = calls -> {:ok, calls}
      calls when is_list(calls) -> {:error, :multiple_tool_calls}
      _ -> {:error, :invalid_tool_calls}
    end
  end

  defp call_name(call) do
    if call_name_value(call) == @tool_name do
      :ok
    else
      {:error, :wrong_tool_name}
    end
  end

  defp call_args(call) do
    cond do
      field(call, :args_error) -> {:error, :invalid_json_arguments}
      is_map(field(call, :args)) -> {:ok, field(call, :args)}
      is_map(field(call, :arguments)) -> {:ok, field(call, :arguments)}
      is_binary(field(call, :arguments)) -> decode_args(field(call, :arguments))
      is_binary(function_field(call, :arguments)) -> decode_args(function_field(call, :arguments))
      true -> {:error, :decoded_non_map_arguments}
    end
  end

  defp decode_args(json) do
    case Jason.decode(json) do
      {:ok, %{} = args} -> {:ok, args}
      {:ok, _} -> {:error, :decoded_non_map_arguments}
      {:error, _} -> {:error, :invalid_json_arguments}
    end
  end

  defp program_arg(args, max_program_bytes) do
    keys = Map.keys(args)

    cond do
      Enum.sort(keys) != ["program"] ->
        {:error, :extra_or_missing_arguments}

      not is_binary(args["program"]) ->
        {:error, :program_not_string}

      String.trim(args["program"]) == "" ->
        {:error, :program_empty}

      byte_size(args["program"]) > max_program_bytes ->
        {:error, :program_too_large}

      true ->
        {:ok, args["program"]}
    end
  end

  defp extract_meta(response) do
    map = if match?({:ok, _}, response), do: elem(response, 1), else: response

    %{
      tokens: map_field(map, :tokens, %{}) || %{},
      model: map_field(map, :model, nil),
      provider: map_field(map, :provider, nil),
      provider_meta: map_field(map, :provider_meta, %{}) || %{}
    }
  end

  defp content_of(%{} = map), do: map_field(map, :content, nil)
  defp content_of(text) when is_binary(text), do: text
  defp content_of(_), do: nil

  defp map_field(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp map_field(_, _key, default), do: default

  defp call_name_value(call), do: field(call, :name) || function_field(call, :name)

  defp function_field(call, key) do
    case field(call, :function) do
      %{} = function -> field(function, key)
      _ -> nil
    end
  end

  defp field(%{} = map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp field(_, _key), do: nil
end
