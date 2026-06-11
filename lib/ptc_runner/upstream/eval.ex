defmodule PtcRunner.Upstream.Eval do
  @moduledoc """
  High-level Lisp orchestration over the upstream runtime.

  Sits above the low-level `PtcRunner.Upstream.Runtime` server: builds a
  per-run `RunContext`, assembles the eval callbacks (`tools:` /
  `discovery_exec:`), and runs PTC-Lisp programs against them.
  """

  alias PtcRunner.SubAgent.{Definition, Runner}
  alias PtcRunner.Upstream.{CallTool, Discovery, RunContext, SideEffectGuard}

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
      RunContext.mark_closed(context)
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
      eval_opts = eval_options(context)

      # The bridge owns the synthetic `"call"` tool; merge it OVER the caller's
      # `:tools` rather than replacing them, so host-granted `tool:` capabilities
      # (e.g. the `log/` introspection prelude) survive on the upstream path and
      # attach-time `tool:` validation can see them. `Map.new/1` canonicalizes the
      # caller's tools from either shape `Lisp.run/2` accepts (map or tuple list).
      merged_tools =
        Map.merge(Map.new(Keyword.get(lisp_opts, :tools, %{})), Keyword.fetch!(eval_opts, :tools))

      # Expose the selected upstream runtime to the prelude attach path so an
      # attached prelude's `requires` are validated against it BEFORE user code
      # runs (plan §6A). `put_new` lets an explicit `:runtime` opt win; absent a
      # prelude this key is inert.
      opts =
        lisp_opts
        |> Keyword.merge(eval_opts)
        |> Keyword.put(:tools, merged_tools)
        |> Keyword.put_new(:runtime, runtime)

      PtcRunner.Lisp.run(program, opts)
    end)
  end

  @doc """
  Run a multi-turn `PtcRunner.SubAgent` over an upstream runtime.

  This is the first-class SubAgent↔upstream bridge. It owns **one**
  `RunContext` spanning the entire multi-turn run (so the ledger, caps, and
  discovery cache aggregate across all turns), derives the upstream `"call"`
  tool + discovery hook from it, enriches the agent's tool map **before** prompt
  generation so the capability is prompt-visible, and threads the runtime handle
  into every turn so attach-time prelude `requires` validation runs fail-closed.
  The SubAgent loop never opens a `RunContext`; this function does.

  Returns `{result, records}` where `result` is the `SubAgent.run/2` result and
  `records` are the drained upstream call records (mirrors
  `run_lisp_with_records/3`).

  ## Options

  All `SubAgent.run/2` opts are forwarded, plus:

    * the upstream context-limit keys (`:max_tool_calls`, `:max_catalog_ops`,
      `:call_timeout_ms`, `:max_response_bytes`, `:max_catalog_result_bytes`) —
      consumed to build the `RunContext`, not forwarded to `SubAgent.run`.
    * `:on_upstream_call` — optional `((args -> result) -> (args -> result))`
      decorator wrapping the upstream `"call"` fn, e.g. a server-side ledger
      that records attempts before dispatch. The mcp ledger lives here.
    * `:allow_call_override` — when `true`, a local `"call"` tool on the agent is
      kept instead of raising on the collision (tests/stubs only).

  `:discovery_exec` and `:runtime` are bridge-owned; any caller-supplied values
  for those keys are ignored.

  The `agent` argument must be a `%PtcRunner.SubAgent.Definition{}` (as built by
  `SubAgent.new/1`): the bridge merges the upstream `"call"` tool into the
  agent's `.tools` map and re-enters the internal `PtcRunner.SubAgent.Runner.run/2`
  rather than the public facade.
  """
  @bridge_keys [:on_upstream_call, :allow_call_override, :discovery_exec, :runtime]

  @spec run_subagent(struct() | pid(), Definition.t(), keyword()) ::
          {{:ok, PtcRunner.Step.t()} | {:error, PtcRunner.Step.t()}, [map()]}
  def run_subagent(runtime, agent, opts \\ []) do
    context_opts = Keyword.take(opts, @context_keys)
    decorate = Keyword.get(opts, :on_upstream_call)
    allow_override = Keyword.get(opts, :allow_call_override, false)
    sub_opts = Keyword.drop(opts, @context_keys ++ @bridge_keys)

    with_run_context(runtime, context_opts, fn context ->
      eval_opts = eval_options(context)
      call_tool = maybe_decorate(eval_opts[:tools], decorate)
      enriched = enrich_agent(agent, call_tool, allow_override)

      run_opts =
        sub_opts
        |> Keyword.put(:discovery_exec, eval_opts[:discovery_exec])
        |> Keyword.put(:runtime, runtime)
        |> Keyword.put_new(:continuation_guard, SideEffectGuard.default(runtime))

      # Internal runner, not the public facade -- pre-empts facade/bridge recursion
      # when the Phase-2 SubAgent.run(runtime:) facade lands (plan section 3.1).
      # Behaviour-preserving today: the %Definition{} clause of SubAgent.run/2 is a
      # pure forward to Runner.run/2.
      Runner.run(enriched, run_opts)
    end)
  end

  defp maybe_decorate(tools, nil), do: tools

  defp maybe_decorate(%{"call" => call} = tools, decorate) when is_function(decorate, 1) do
    %{tools | "call" => decorate.(call)}
  end

  # Merge the upstream `"call"` tool into the agent BEFORE the agent runs so it is
  # visible both in the first-turn prompt and in every per-turn execution surface
  # (both re-derive from `agent.tools`). Reserve `"call"` for the upstream tool: a
  # silent local override would make prelude `requires` validation (against the
  # runtime) disagree with execution (a local fn).
  #
  # Matches `%Definition{}` specifically (not just any `%{tools: _}`): the bridge
  # is Definition-only (see `@spec`), so a non-Definition agent fails closed here
  # with `FunctionClauseError` rather than slipping through enrich to raise later.
  defp enrich_agent(%Definition{tools: tools} = agent, call_tool, allow_override) do
    cond do
      not Map.has_key?(tools, "call") ->
        %{agent | tools: Map.merge(tools, call_tool)}

      allow_override ->
        # Caller explicitly keeps its local "call" (tests/stubs).
        %{agent | tools: Map.merge(call_tool, tools)}

      true ->
        raise ArgumentError,
              "agent defines a local \"call\" tool that collides with the upstream " <>
                "call tool; pass `allow_call_override: true` to keep the local one " <>
                "(tests/stubs only)"
    end
  end
end
