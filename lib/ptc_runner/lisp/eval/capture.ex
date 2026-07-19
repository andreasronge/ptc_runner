defmodule PtcRunner.Lisp.Eval.Capture do
  @moduledoc false

  alias PtcRunner.Lisp.Eval.Abort
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Effects

  @key :__ptc_effect_capture_stack__

  defmodule Frame do
    @moduledoc false

    alias PtcRunner.Lisp.Eval.Effects

    defstruct baseline: %Effects{}, effects: %Effects{}, cumulative: %Effects{}

    @type t :: %__MODULE__{
            baseline: Effects.t(),
            effects: Effects.t(),
            cumulative: Effects.t()
          }
  end

  @type value_result ::
          {:ok, term(), EvalContext.t()}
          | {:raise, :error | :exit | :throw, term(), Exception.stacktrace(), EvalContext.t()}

  @doc false
  @spec run_value(EvalContext.t(), (-> term())) :: value_result()
  def run_value(%EvalContext{} = context, fun) when is_function(fun, 0) do
    baseline_context = materialize_context(context)
    push(baseline_context.effects)

    try do
      value = fun.()
      frame = pop()
      final_context = normalize_context(baseline_context, frame)
      merge_into_parent(frame.effects)
      {:ok, value, final_context}
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        frame = pop()

        final_context =
          reason
          |> context_from_reason(baseline_context)
          |> normalize_context(frame)

        merge_into_parent(frame.effects)
        {:raise, kind, reason, stacktrace, final_context}
    end
  end

  @doc false
  @spec run_outcome(EvalContext.t(), (-> term())) :: term()
  def run_outcome(%EvalContext{} = context, fun) when is_function(fun, 0) do
    case run_value(context, fun) do
      {:ok, {:ok, value, %EvalContext{} = final_context}, captured_context} ->
        {:ok, value, replace_effects(final_context, captured_context.effects)}

      {:ok, {:error, reason, %EvalContext{} = final_context}, captured_context} ->
        {:error, reason, replace_effects(final_context, captured_context.effects)}

      {:ok, {:control, signal, value, %EvalContext{} = final_context}, captured_context}
      when signal in [:return, :fail, :recur] ->
        {:control, signal, value, replace_effects(final_context, captured_context.effects)}

      {:ok, other, _captured_context} ->
        raise ArgumentError,
              "capture outcome callback returned an invalid evaluator outcome: #{inspect(other)}"

      {:raise, :error, %Abort{outcome: outcome}, _stacktrace, captured_context} ->
        normalize_outcome(outcome, captured_context)

      {:raise, _kind, _reason, _stacktrace, _context} = raised ->
        raised
    end
  end

  @doc false
  @spec materialize_context(EvalContext.t()) :: EvalContext.t()
  def materialize_context(%EvalContext{} = context) do
    case Process.get(@key, []) do
      [%Frame{} = frame | _rest] ->
        replace_effects(context, frame.cumulative)

      [] ->
        context
    end
  end

  @doc false
  @spec record_print(String.t()) :: :ok
  def record_print(message) when is_binary(message),
    do: record(&Effects.record_print(&1, message))

  @doc false
  @spec record_tool_call(map()) :: :ok
  def record_tool_call(tool_call) when is_map(tool_call),
    do: record(&Effects.record_tool_call(&1, tool_call))

  @doc false
  @spec record_pmap_call(map()) :: :ok
  def record_pmap_call(pmap_call) when is_map(pmap_call),
    do: record(&Effects.record_pmap_call(&1, pmap_call))

  @doc false
  @spec record_prelude_call(String.t()) :: :ok
  def record_prelude_call(ref) when is_binary(ref),
    do: record(&Effects.record_prelude_call(&1, ref))

  @doc false
  @spec record_cache(term(), term()) :: :ok
  def record_cache(key, value),
    do: record(&Effects.record_cache(&1, key, value))

  @doc false
  @spec record_effects(Effects.t()) :: :ok
  def record_effects(%Effects{} = effects),
    do: record(&Effects.merge(effects, &1))

  @doc false
  @spec current_effects() :: Effects.t()
  def current_effects do
    case Process.get(@key, []) do
      [%Frame{effects: effects} | _rest] -> effects
      [] -> Effects.empty()
    end
  end

  @doc false
  @spec baseline_effects() :: Effects.t()
  def baseline_effects do
    case Process.get(@key, []) do
      [%Frame{baseline: baseline} | _rest] -> baseline
      [] -> Effects.empty()
    end
  end

  @doc false
  @spec empty?() :: boolean()
  def empty?, do: Process.get(@key, []) == []

  defp push(%Effects{} = baseline) do
    Process.put(
      @key,
      [%Frame{baseline: baseline, cumulative: baseline} | Process.get(@key, [])]
    )

    :ok
  end

  defp pop do
    case Process.get(@key, []) do
      [%Frame{} = frame | rest] ->
        put_stack(rest)
        frame

      [] ->
        %Frame{}
    end
  end

  defp merge_into_parent(%Effects{} = effects), do: record_effects(effects)

  defp normalize_context(%EvalContext{} = context, %Frame{} = frame) do
    replace_effects(context, frame.cumulative)
  end

  defp context_from_reason({_, _, %EvalContext{} = context}, _fallback), do: context

  defp context_from_reason(%Abort{outcome: outcome}, fallback),
    do: outcome_context(outcome, fallback)

  defp context_from_reason(%{eval_ctx: %EvalContext{} = context}, _fallback), do: context
  defp context_from_reason(_reason, %EvalContext{} = fallback), do: fallback

  defp replace_effects(%EvalContext{} = context, %Effects{} = effects),
    do: %{context | effects: effects}

  defp normalize_outcome({:ok, value, %EvalContext{} = context}, captured),
    do: {:ok, value, replace_effects(context, captured.effects)}

  defp normalize_outcome({:error, reason, %EvalContext{} = context}, captured),
    do: {:error, reason, replace_effects(context, captured.effects)}

  defp normalize_outcome({:control, signal, value, %EvalContext{} = context}, captured)
       when signal in [:return, :fail, :recur],
       do: {:control, signal, value, replace_effects(context, captured.effects)}

  defp outcome_context({_, _, %EvalContext{} = context}, _fallback), do: context
  defp outcome_context({:control, _, _, %EvalContext{} = context}, _fallback), do: context
  defp outcome_context(_outcome, fallback), do: fallback

  defp record(fun) when is_function(fun, 1) do
    update(fn frame ->
      %{frame | effects: fun.(frame.effects), cumulative: fun.(frame.cumulative)}
    end)
  end

  defp update(fun) do
    case Process.get(@key, []) do
      [%Frame{} = frame | rest] -> Process.put(@key, [fun.(frame) | rest])
      [] -> :ok
    end

    :ok
  end

  defp put_stack([]), do: Process.delete(@key)
  defp put_stack(stack), do: Process.put(@key, stack)
end
