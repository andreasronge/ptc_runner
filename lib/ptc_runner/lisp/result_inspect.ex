defimpl Inspect, for: PtcRunner.Lisp.Result do
  alias PtcRunner.Lisp.RetainedSize

  @count_limit 10_000

  def inspect(result, _opts) do
    "#PtcRunner.Lisp.Result<" <>
      Enum.join(
        [
          field("outcome", outcome(result)),
          field("memory_entries", map_count(result.memory)),
          field("memory_bytes", retained_bytes(result.memory)),
          field("turns", list_count(result.turns)),
          field("prints", list_count(result.prints)),
          field("tool_calls", list_count(result.tool_calls)),
          field("pmap_calls", list_count(result.pmap_calls)),
          field("child_traces", list_count(result.child_traces)),
          field("child_steps", list_count(result.child_steps)),
          field("messages", list_count(result.messages)),
          field("prelude_calls", map_count(result.prelude_call_counts))
        ],
        ", "
      ) <> ">"
  end

  defp outcome(%{fail: nil}), do: "ok"
  defp outcome(%{}), do: "error"

  defp map_count(value) when is_map(value), do: map_size(value)
  defp map_count(_value), do: "unknown"

  defp list_count(value) when is_list(value), do: bounded_list_count(value, 0)
  defp list_count(nil), do: 0
  defp list_count(_value), do: "unknown"

  defp bounded_list_count([], count), do: count
  defp bounded_list_count(_rest, @count_limit), do: "#{@count_limit}+"
  defp bounded_list_count([_item | rest], count), do: bounded_list_count(rest, count + 1)
  defp bounded_list_count(_improper, _count), do: "unknown"

  defp retained_bytes(value) do
    case RetainedSize.bytes(value) do
      bytes when is_integer(bytes) -> bytes
      :oversized -> "unknown"
    end
  end

  defp field(name, value), do: name <> ": " <> to_string(value)
end
