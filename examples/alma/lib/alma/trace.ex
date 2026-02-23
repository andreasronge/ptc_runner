defmodule Alma.Trace do
  @moduledoc """
  Emits trace events compatible with ptc_viewer.

  Uses `PtcRunner.SubAgent.Telemetry.span/3` to emit standard tool-style
  events that the TraceLog handler captures and ptc_viewer can render.
  """

  alias PtcRunner.SubAgent.Telemetry
  alias PtcRunner.Lisp.CoreToSource

  @doc """
  Wraps a function in a tool-style telemetry span visible in ptc_viewer.

  The `name` appears as a tool call in the trace viewer.
  """
  def span(name, metadata \\ %{}, fun) when is_function(fun, 0) do
    Telemetry.span([:tool], %{tool_name: name, args: metadata}, fn ->
      case fun.() do
        {:__trace_meta__, result, %{} = extra_meta} ->
          stop = Map.merge(%{tool_name: name, result: summarize(result)}, extra_meta)
          {result, stop}

        result ->
          {result, %{tool_name: name, result: summarize(result)}}
      end
    end)
  end

  defp summarize(%_{} = struct), do: %{"value" => inspect(struct, limit: 200)}
  defp summarize(value) when is_map(value), do: summarize_map(value)
  defp summarize(value) when is_list(value), do: %{"count" => length(value)}
  defp summarize(value), do: %{"value" => inspect(value, limit: 200)}

  # Convert closure tuples in maps to readable PTC-Lisp source.
  defp summarize_map(map) do
    has_closures? = Enum.any?(map, fn {_k, v} -> match?({:closure, _, _, _, _, _}, v) end)

    if has_closures? do
      Map.new(map, fn
        {k, {:closure, _, _, _, _, _} = closure} ->
          {k, CoreToSource.serialize_closure(closure)}

        {k, v} ->
          {k, v}
      end)
    else
      map
    end
  end
end
