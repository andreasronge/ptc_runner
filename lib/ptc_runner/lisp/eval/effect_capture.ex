defmodule PtcRunner.Lisp.Eval.EffectCapture do
  @moduledoc false

  alias PtcRunner.Lisp.Eval.Effects

  @key :__ptc_parallel_effect_capture_stack__

  @spec push() :: :ok
  def push do
    Process.put(@key, [empty() | Process.get(@key, [])])
    :ok
  end

  @spec pop() :: Effects.t()
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
  def record_prelude_call(ref) when is_binary(ref),
    do: update(&Effects.record_prelude_call(&1, ref))

  @spec record_cache(term(), term()) :: :ok
  def record_cache(key, value), do: update(&Effects.record_cache(&1, key, value))

  @spec record_effects(Effects.t()) :: :ok
  def record_effects(%Effects{} = effects), do: update(&Effects.merge(effects, &1))

  @spec empty() :: Effects.t()
  def empty, do: Effects.empty()

  defp update_list(field, value) do
    update(fn effects ->
      case field do
        :prints -> Effects.record_print(effects, value)
        :tool_calls -> Effects.record_tool_call(effects, value)
        :pmap_calls -> Effects.record_pmap_call(effects, value)
      end
    end)
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
