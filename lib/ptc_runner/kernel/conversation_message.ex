defmodule PtcRunner.Kernel.ConversationMessage do
  @moduledoc false

  alias PtcRunner.Lisp.Runtime.String, as: RuntimeString

  @spec assistant(term()) :: map()
  def assistant(%{"value" => value}) when is_map(value) do
    value
    |> Map.take(["content", "tool_calls"])
    |> Map.put("role", "assistant")
    |> ensure_assistant_content(value)
  end

  def assistant(result), do: %{"role" => "assistant", "content" => result}

  @spec comparable(term()) :: term()
  def comparable(%{"role" => "assistant", "tool_calls" => [_ | _]} = message) do
    case Map.get(message, "content") do
      nil -> Map.put(message, "content", nil)
      content when is_binary(content) -> normalize_blank_content(message, content)
      _other -> message
    end
  end

  def comparable(message), do: message

  defp ensure_assistant_content(%{"role" => "assistant"} = message, value)
       when map_size(message) == 1,
       do: Map.put(message, "content", value)

  defp ensure_assistant_content(message, _value), do: message

  defp normalize_blank_content(message, content) do
    if RuntimeString.blank?(content),
      do: Map.put(message, "content", nil),
      else: message
  end
end
