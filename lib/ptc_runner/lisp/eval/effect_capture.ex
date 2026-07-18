defmodule PtcRunner.Lisp.Eval.EffectCapture do
  @moduledoc false

  @key :__ptc_parallel_effect_capture_stack__

  @type effects :: %{
          tool_calls: [map()],
          pmap_calls: [map()],
          prints: [String.t()],
          prelude_call_counts: %{String.t() => non_neg_integer()},
          tool_cache: map()
        }

  @spec push() :: :ok
  def push do
    Process.put(@key, [empty() | Process.get(@key, [])])
    :ok
  end

  @spec pop() :: effects()
  def pop do
    case Process.get(@key, []) do
      [effects | rest] ->
        put_stack(rest)
        effects

      [] ->
        empty()
    end
  end

  @spec record_print(String.t()) :: :ok
  def record_print(message) when is_binary(message), do: update_list(:prints, message)

  @spec record_tool_call(map()) :: :ok
  def record_tool_call(tool_call) when is_map(tool_call), do: update_list(:tool_calls, tool_call)

  @spec record_pmap_call(map()) :: :ok
  def record_pmap_call(pmap_call) when is_map(pmap_call), do: update_list(:pmap_calls, pmap_call)

  @spec record_prelude_call(String.t()) :: :ok
  def record_prelude_call(ref) when is_binary(ref) do
    update(fn effects ->
      Map.update!(
        effects,
        :prelude_call_counts,
        &Map.update(&1, ref, 1, fn count -> count + 1 end)
      )
    end)
  end

  @spec record_cache(term(), term()) :: :ok
  def record_cache(key, value) do
    update(&Map.update!(&1, :tool_cache, fn cache -> Map.put(cache, key, value) end))
  end

  @spec record_effects(effects()) :: :ok
  def record_effects(effects) when is_map(effects) do
    update(fn captured ->
      %{
        tool_calls: Map.fetch!(effects, :tool_calls) ++ captured.tool_calls,
        pmap_calls: Map.fetch!(effects, :pmap_calls) ++ captured.pmap_calls,
        prints: Map.fetch!(effects, :prints) ++ captured.prints,
        prelude_call_counts:
          Map.merge(
            captured.prelude_call_counts,
            Map.fetch!(effects, :prelude_call_counts),
            fn _ref, left, right -> left + right end
          ),
        tool_cache: Map.merge(captured.tool_cache, Map.fetch!(effects, :tool_cache))
      }
    end)
  end

  @spec empty() :: effects()
  def empty do
    %{tool_calls: [], pmap_calls: [], prints: [], prelude_call_counts: %{}, tool_cache: %{}}
  end

  defp update_list(field, value) do
    update(&Map.update!(&1, field, fn values -> [value | values] end))
  end

  defp update(fun) do
    case Process.get(@key, []) do
      [effects | rest] -> Process.put(@key, [fun.(effects) | rest])
      [] -> :ok
    end

    :ok
  end

  defp put_stack([]), do: Process.delete(@key)
  defp put_stack(stack), do: Process.put(@key, stack)
end
