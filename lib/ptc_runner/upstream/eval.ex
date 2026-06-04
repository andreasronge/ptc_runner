defmodule PtcRunner.Upstream.Eval do
  @moduledoc """
  High-level Lisp orchestration over the upstream runtime.

  Sits above the low-level `PtcRunner.Upstream.Runtime` server: builds a
  per-run `RunContext`, assembles the eval callbacks (`tools:` /
  `discovery_exec:`), and runs PTC-Lisp programs against them.
  """

  alias PtcRunner.Upstream.{CallTool, Discovery, RunContext}

  @context_keys [
    :max_tool_calls,
    :max_catalog_ops,
    :call_timeout_ms,
    :max_response_bytes,
    :max_catalog_result_bytes
  ]

  @spec run_context(struct() | pid(), keyword()) :: {:ok, struct()} | {:error, term()}
  def run_context(runtime, opts \\ []), do: RunContext.new(runtime, opts)

  @spec eval_options(struct()) :: keyword()
  def eval_options(%RunContext{} = context) do
    [
      tools: CallTool.build(context),
      discovery_exec: Discovery.build(context)
    ]
  end

  @spec with_run_context(struct() | pid(), keyword(), (struct() -> term())) ::
          {term(), [map()]}
  def with_run_context(runtime, opts, fun) when is_function(fun, 1) do
    {:ok, context} = run_context(runtime, opts)

    try do
      result = fun.(context)
      records = RunContext.drain_calls(context)
      {result, records}
    after
      RunContext.close(context)
    end
  end

  @spec run_lisp(struct() | pid(), String.t(), keyword()) ::
          {:ok, PtcRunner.Step.t()} | {:error, PtcRunner.Step.t()}
  def run_lisp(runtime, program, opts \\ []) do
    {result, _records} = run_lisp_with_records(runtime, program, opts)
    result
  end

  @doc false
  @spec run_lisp_with_records(struct() | pid(), String.t(), keyword()) ::
          {{:ok, PtcRunner.Step.t()} | {:error, PtcRunner.Step.t()}, [map()]}
  def run_lisp_with_records(runtime, program, opts \\ []) do
    context_opts = Keyword.take(opts, @context_keys)
    lisp_opts = Keyword.drop(opts, @context_keys)

    with_run_context(runtime, context_opts, fn context ->
      # Expose the selected upstream runtime to the prelude attach path so an
      # attached prelude's `requires` are validated against it BEFORE user code
      # runs (plan §6A). `put_new` lets an explicit `:runtime` opt win; absent a
      # prelude this key is inert.
      opts =
        lisp_opts
        |> Keyword.merge(eval_options(context))
        |> Keyword.put_new(:runtime, runtime)

      PtcRunner.Lisp.run(program, opts)
    end)
  end
end
