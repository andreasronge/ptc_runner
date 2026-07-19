defmodule PtcRunner.Lisp.RuntimeCallable do
  @moduledoc """
  Runtime callable for effectful qualified Lisp symbols.

  Values such as `tool/search` are not plain functions: they need an evaluator
  context to enforce limits, record traces, and call the configured runtime
  executor. The persisted value only carries the qualified name. A short-lived
  bound form is created at application time for higher-order runtime calls.
  """

  alias PtcRunner.Lisp.Eval.Abort
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Eval.HostContext

  defstruct [:namespace, :name, :eval_ctx, :do_eval]

  @type namespace :: :tool
  @type t :: %__MODULE__{
          namespace: namespace(),
          name: atom(),
          eval_ctx: EvalContext.t() | nil,
          do_eval:
            (term(), EvalContext.t() -> {:ok, term(), EvalContext.t()} | {:error, term()})
            | nil
        }

  @spec new(namespace(), atom()) :: t()
  def new(namespace, name) do
    %__MODULE__{namespace: namespace, name: name}
  end

  @spec bind(t(), EvalContext.t(), function()) :: t()
  def bind(%__MODULE__{} = callable, %EvalContext{} = eval_ctx, do_eval)
      when is_function(do_eval, 2) do
    %{callable | eval_ctx: eval_ctx, do_eval: do_eval}
  end

  @spec label(t()) :: String.t()
  def label(%__MODULE__{namespace: namespace, name: name}), do: "#{namespace}/#{name}"

  @spec invoke(t(), [term()], EvalContext.t()) ::
          {:ok, term(), EvalContext.t()} | {:error, term()}
  def invoke(%__MODULE__{} = callable, args, %EvalContext{} = eval_ctx) do
    with {:ok, ast} <- core_call(callable, args) do
      callable.do_eval.(ast, eval_ctx)
    end
  end

  @spec call(t(), [term()]) :: term()
  def call(%__MODULE__{eval_ctx: %EvalContext{}, do_eval: do_eval} = callable, args)
      when is_function(do_eval, 2) do
    call_with_context(callable, args, callable.eval_ctx, do_eval)
  end

  def call(%__MODULE__{} = callable, args) do
    case HostContext.current() do
      {%EvalContext{} = eval_ctx, do_eval} ->
        call_with_context(callable, args, eval_ctx, do_eval)

      _ ->
        HostContext.error!(
          {:runtime_error, "#{label(callable)} is not bound to the current evaluation context"}
        )
    end
  end

  defp call_with_context(%__MODULE__{} = callable, args, %EvalContext{} = base_ctx, do_eval)
       when is_function(do_eval, 2) do
    HostContext.with_materialized_context(base_ctx, do_eval, fn eval_ctx ->
      callable = bind(callable, eval_ctx, do_eval)

      case invoke(callable, args, eval_ctx) do
        {:ok, result, _final_ctx} ->
          result

        {:error, reason} ->
          Abort.error!(error_reason(reason), eval_ctx)
      end
    end)
  end

  @spec serializable?(term()) :: boolean()
  def serializable?(%__MODULE__{}), do: false
  def serializable?(_), do: true

  defp core_call(%__MODULE__{namespace: :tool, name: name}, args) do
    {:ok, {:tool_call, name, literal_args(args)}}
  end

  defp core_call(%__MODULE__{} = callable, _args) do
    {:error, {:invalid_form, "Unknown runtime callable: #{label(callable)}"}}
  end

  defp literal_args(args), do: Enum.map(args, &{:literal, &1})

  defp error_reason({reason, message, data}) when is_atom(reason) and is_binary(message),
    do: {reason, message, data}

  defp error_reason({reason, message}) when is_atom(reason) and is_binary(message),
    do: {reason, message, nil}

  defp error_reason({reason, _} = error) when is_atom(reason),
    do: {reason, Helpers.format_closure_error(error), nil}

  defp error_reason(reason), do: {:runtime_error, Helpers.format_closure_error(reason)}
end
