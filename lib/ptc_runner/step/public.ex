defmodule PtcRunner.Step.Public do
  @moduledoc """
  Public rendering for native `%PtcRunner.Step.Native{}` values.

  Runtime code may keep PTC-Lisp values in their native representation so
  continuation state preserves keyword/function semantics across turns. This
  module is the public boundary: it converts native values into the Elixir/JSON
  facing shape expected from `SubAgent.run/2`, `Session.eval/3`, and similar
  APIs.
  """

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.RuntimeCallable
  alias PtcRunner.Step
  alias PtcRunner.Step.Native
  alias PtcRunner.SubAgent.KeyNormalizer

  @type render_opt ::
          {:memory, :public | :native}
          | {:return, :public | :native}
          | {:turns, :public | :native}
          | {:normalize_return_keys, boolean()}

  @spec from_native(Native.t(), [render_opt()]) :: Step.t()
  def from_native(%Native{} = step, opts \\ []) do
    %Step{
      return: render_return(step.return, opts),
      fail: render_fail(step.fail),
      memory: render_memory(step.memory, Keyword.get(opts, :memory, :public)),
      journal: render_value(step.journal),
      signature: step.signature,
      usage: step.usage,
      turns: render_turns(step.turns, Keyword.get(opts, :turns, :public)),
      trace_id: step.trace_id,
      parent_trace_id: step.parent_trace_id,
      name: step.name,
      field_descriptions: step.field_descriptions,
      prints: step.prints,
      tool_calls: render_tool_calls(step.tool_calls),
      pmap_calls: render_value(step.pmap_calls),
      catalog_ops: render_value(step.catalog_ops),
      child_traces: step.child_traces,
      child_steps: render_child_steps(step.child_steps, opts),
      messages: step.messages,
      prompt: step.prompt,
      original_prompt: step.original_prompt,
      tools: step.tools,
      prelude_trace: step.prelude_trace,
      prelude_call_counts: step.prelude_call_counts,
      summaries: step.summaries,
      tool_cache: render_value(step.tool_cache)
    }
  end

  @spec render(Native.t(), [render_opt()]) :: Step.t()
  def render(%Native{} = step, opts \\ []), do: from_native(step, opts)

  @spec value(term()) :: term()
  def value(value), do: render_value(value)

  @spec memory(map()) :: map()
  def memory(memory), do: render_public_memory(memory)

  @spec turns(term()) :: term()
  def turns(turns), do: render_turns(turns, :public)

  defp render_return(value, opts) do
    value =
      case Keyword.get(opts, :return, :public) do
        :native -> value
        :public -> render_value(value)
      end

    if Keyword.get(opts, :normalize_return_keys, true) do
      KeyNormalizer.normalize_keys(value)
    else
      value
    end
  end

  defp render_fail(nil), do: nil
  defp render_fail(fail), do: render_value(fail)

  defp render_memory(memory, :native), do: memory
  defp render_memory(memory, :public), do: render_public_memory(memory || %{})

  defp render_turns(turns, :native), do: turns

  defp render_turns(turns, :public) when is_list(turns) do
    Enum.map(turns, fn
      %{} = turn ->
        turn
        |> maybe_render_turn_memory()
        |> maybe_render_turn_result()
        |> maybe_render_turn_tool_calls()

      turn ->
        turn
    end)
  end

  defp render_turns(turns, :public), do: turns

  defp maybe_render_turn_memory(%{memory: memory} = turn) do
    %{turn | memory: render_public_memory(memory || %{})}
  end

  defp maybe_render_turn_memory(turn), do: turn

  defp maybe_render_turn_result(%{result: result} = turn) do
    %{turn | result: render_value(result)}
  end

  defp maybe_render_turn_result(turn), do: turn

  defp maybe_render_turn_tool_calls(%{tool_calls: tool_calls} = turn) do
    %{turn | tool_calls: render_tool_calls(tool_calls)}
  end

  defp maybe_render_turn_tool_calls(turn), do: turn

  defp render_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn
      %{args: args, result: result} = tool_call ->
        %{tool_call | args: render_value(args), result: render_value(result)}

      %{args: args} = tool_call ->
        %{tool_call | args: render_value(args)}

      %{result: result} = tool_call ->
        %{tool_call | result: render_value(result)}

      tool_call ->
        render_value(tool_call)
    end)
  end

  defp render_tool_calls(tool_calls), do: tool_calls

  defp render_public_memory(memory),
    do: memory |> Lisp.externalize_memory() |> render_opaque_values()

  defp render_value(value), do: value |> Lisp.externalize_value() |> render_opaque_values()

  defp render_opaque_values(%Native{} = step), do: from_native(step)

  defp render_opaque_values({:closure, _params, _body, _env, _turn_history, _metadata} = closure) do
    closure
    |> Format.to_clojure()
    |> elem(0)
  end

  defp render_opaque_values(%LispKeyword{} = keyword), do: Lisp.externalize_value(keyword)

  defp render_opaque_values(%RuntimeCallable{} = callable), do: Lisp.externalize_value(callable)

  defp render_opaque_values(value) when is_list(value) do
    Enum.map(value, &render_opaque_values/1)
  end

  defp render_opaque_values(%MapSet{} = set) do
    set
    |> Enum.map(&render_opaque_values/1)
    |> MapSet.new()
  end

  defp render_opaque_values(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&render_opaque_values/1)
    |> List.to_tuple()
  end

  defp render_opaque_values(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} ->
      {render_opaque_values(key), render_opaque_values(inner)}
    end)
  end

  defp render_opaque_values(value), do: value

  defp render_child_steps(nil, _opts), do: nil
  defp render_child_steps([], _opts), do: []

  defp render_child_steps(child_steps, opts) when is_list(child_steps) do
    Enum.map(child_steps, fn
      %Native{} = child -> from_native(child, opts)
      other -> other
    end)
  end

  defp render_child_steps(child_steps, _opts), do: child_steps
end
