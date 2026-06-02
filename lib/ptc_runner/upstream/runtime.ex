defmodule PtcRunner.Upstream.Runtime do
  @moduledoc """
  OTP-backed upstream runtime handle for root `ptc_runner` callers.
  """

  use GenServer

  alias PtcRunner.Upstream.{Catalog, Config, Credentials, OpenAPI, RunContext}
  alias PtcRunner.Upstream.Transport.McpHttp
  alias PtcRunner.Upstream.Transport.McpStdio

  defstruct [:pid, :catalog_exposure_mode, :catalog_snapshot_mode]

  @defaults %{
    max_tool_calls: 50,
    max_catalog_ops: 25,
    call_timeout_ms: 5_000,
    max_response_bytes: 2 * 1024 * 1024,
    max_catalog_result_bytes: 262_144
  }

  @spec start_link(keyword()) :: {:ok, %__MODULE__{}} | :ignore | {:error, term()}
  def start_link(opts \\ []) do
    parent_trap = Process.flag(:trap_exit, true)

    try do
      start_process(opts)
    after
      Process.flag(:trap_exit, parent_trap)
    end
    |> case do
      {:ok, pid} ->
        {:ok,
         %__MODULE__{
           pid: pid,
           catalog_exposure_mode: Keyword.get(opts, :catalog_exposure_mode, :auto),
           catalog_snapshot_mode: Keyword.get(opts, :catalog_snapshot_mode, :live)
         }}

      other ->
        other
    end
  end

  @doc false
  def start_supervised(opts \\ []), do: start_process(opts)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_supervised, [opts]},
      type: :worker
    }
  end

  @spec stop(struct() | pid()) :: :ok
  def stop(%__MODULE__{pid: pid}), do: stop(pid)

  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  def stop(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> stop(pid)
    end
  end

  @spec run_context(struct() | pid(), keyword()) :: {:ok, struct()} | {:error, term()}
  def run_context(runtime, opts \\ []), do: RunContext.new(runtime, opts)

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
    context_opts =
      Keyword.take(opts, [
        :max_tool_calls,
        :max_catalog_ops,
        :call_timeout_ms,
        :max_response_bytes,
        :max_catalog_result_bytes
      ])

    lisp_opts =
      Keyword.drop(opts, [
        :max_tool_calls,
        :max_catalog_ops,
        :call_timeout_ms,
        :max_response_bytes,
        :max_catalog_result_bytes
      ])

    {result, _records} =
      with_run_context(runtime, context_opts, fn context ->
        PtcRunner.Lisp.run(program, Keyword.merge(lisp_opts, RunContext.eval_options(context)))
      end)

    result
  end

  @doc false
  @spec run_lisp_with_records(struct() | pid(), String.t(), keyword()) ::
          {{:ok, PtcRunner.Step.t()} | {:error, PtcRunner.Step.t()}, [map()]}
  def run_lisp_with_records(runtime, program, opts \\ []) do
    context_opts =
      Keyword.take(opts, [
        :max_tool_calls,
        :max_catalog_ops,
        :call_timeout_ms,
        :max_response_bytes,
        :max_catalog_result_bytes
      ])

    lisp_opts =
      Keyword.drop(opts, [
        :max_tool_calls,
        :max_catalog_ops,
        :call_timeout_ms,
        :max_response_bytes,
        :max_catalog_result_bytes
      ])

    with_run_context(runtime, context_opts, fn context ->
      PtcRunner.Lisp.run(program, Keyword.merge(lisp_opts, RunContext.eval_options(context)))
    end)
  end

  @spec defaults(struct() | pid()) :: map()
  def defaults(runtime), do: call(runtime, :defaults)

  @spec upstream(struct() | pid(), String.t()) :: map() | nil
  def upstream(runtime, name), do: call(runtime, {:upstream, name})

  @spec upstream_names(struct() | pid()) :: [String.t()]
  def upstream_names(runtime), do: call(runtime, :upstream_names)

  @spec call_tool(struct() | pid(), String.t(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, atom(), String.t()}
  def call_tool(runtime, server, tool, args, opts) do
    case upstream(runtime, server) do
      %{transport: :openapi} = upstream ->
        OpenAPI.call(upstream, tool, args, opts)

      %{transport: :mcp_stdio, client_pid: pid} = upstream when is_pid(pid) ->
        McpStdio.call(upstream, tool, args, opts)

      %{transport: :mcp_http, client_pid: pid} = upstream when is_pid(pid) ->
        McpHttp.call(upstream, tool, args, opts)

      %{transport: transport} when transport in [:mcp_stdio, :mcp_http] ->
        {:error, :upstream_unavailable, "upstream #{server} is unavailable"}

      nil ->
        {:error, :upstream_unavailable, "upstream #{server} is not configured"}
    end
  end

  @spec scrub(struct() | pid(), term()) :: term()
  def scrub(runtime, term), do: call(runtime, {:scrub, term})

  @spec catalog_snapshot(struct() | pid()) :: [map()]
  def catalog_snapshot(runtime), do: call(runtime, :catalog_snapshot)

  @spec catalog_text(struct() | pid()) :: String.t()
  def catalog_text(runtime), do: call(runtime, :catalog_text)

  @spec diagnostics(struct() | pid()) :: map()
  def diagnostics(runtime), do: call(runtime, :diagnostics)

  @doc false
  @spec redaction_secrets(struct() | pid()) :: [String.t()]
  def redaction_secrets(runtime), do: call(runtime, :redaction_secrets)

  @impl GenServer
  def init(opts) do
    snapshot_mode = Keyword.get(opts, :catalog_snapshot_mode, :live)

    with {:ok, %{credentials: credentials, upstreams: upstreams}} <- Config.load(opts),
         {:ok, upstreams} <- prepare_upstreams(upstreams, snapshot_mode) do
      exposure = Keyword.get(opts, :catalog_exposure_mode, :auto)
      catalog_inline_max_chars = Keyword.get(opts, :catalog_inline_max_chars, 800)
      catalog_inline_max_tools = Keyword.get(opts, :catalog_inline_max_tools, 8)
      upstream_map = Map.new(upstreams, &{&1.name, &1})
      snapshot = scrubbed_snapshot(credentials, upstreams)
      :ok = maybe_register_redaction_secrets(credentials, opts)

      {:ok,
       %{
         credentials: credentials,
         upstreams: upstream_map,
         catalog_exposure_mode: exposure,
         catalog_snapshot_mode: snapshot_mode,
         catalog_inline_max_chars: catalog_inline_max_chars,
         catalog_inline_max_tools: catalog_inline_max_tools,
         snapshot: snapshot,
         defaults: %{
           max_tool_calls: Keyword.get(opts, :max_tool_calls, @defaults.max_tool_calls),
           max_catalog_ops: Keyword.get(opts, :max_catalog_ops, @defaults.max_catalog_ops),
           call_timeout_ms: Keyword.get(opts, :call_timeout_ms, @defaults.call_timeout_ms),
           max_response_bytes:
             Keyword.get(opts, :max_response_bytes, @defaults.max_response_bytes),
           max_catalog_result_bytes:
             Keyword.get(opts, :max_catalog_result_bytes, @defaults.max_catalog_result_bytes)
         }
       }}
    else
      {:error, reason, detail} -> {:stop, {reason, detail}}
    end
  end

  @impl GenServer
  def handle_call(:defaults, _from, state), do: {:reply, state.defaults, state}

  def handle_call(:upstream_names, _from, state),
    do: {:reply, Map.keys(state.upstreams) |> Enum.sort(), state}

  def handle_call({:upstream, name}, _from, state) do
    case Map.get(state.upstreams, name) do
      nil ->
        {:reply, nil, state}

      upstream ->
        {upstream, state} = ensure_upstream_tools(upstream, state)
        {:reply, upstream, state}
    end
  end

  def handle_call(:catalog_snapshot, _from, state) do
    {snapshot, state} = current_snapshot(state)
    {:reply, snapshot, state}
  end

  def handle_call(:catalog_text, _from, state) do
    {snapshot, state} = current_snapshot(state)

    text =
      Catalog.render_text(snapshot, state.catalog_exposure_mode,
        catalog_inline_max_chars: state.catalog_inline_max_chars,
        catalog_inline_max_tools: state.catalog_inline_max_tools
      )

    {:reply, text, state}
  end

  def handle_call({:scrub, term}, _from, state),
    do: {:reply, Credentials.scrub(state.credentials, term), state}

  def handle_call(:redaction_secrets, _from, state),
    do: {:reply, Credentials.redaction_secrets(state.credentials), state}

  def handle_call(:diagnostics, _from, state) do
    {:reply,
     %{
       upstreams: Map.keys(state.upstreams) |> Enum.sort(),
       catalog_exposure_mode: state.catalog_exposure_mode,
       catalog_snapshot_mode: state.catalog_snapshot_mode,
       transports:
         state.upstreams |> Enum.map(fn {name, up} -> {name, up.transport} end) |> Map.new(),
       limits: state.defaults
     }, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    state.upstreams
    |> Map.values()
    |> Enum.each(fn
      %{client_pid: pid} when is_pid(pid) -> GenServer.stop(pid, :normal, 5_000)
      _ -> :ok
    end)

    :ok
  catch
    :exit, _ -> :ok
  end

  defp call(%__MODULE__{pid: pid}, message), do: GenServer.call(pid, message)
  defp call(pid, message) when is_pid(pid), do: GenServer.call(pid, message)
  defp call(name, message) when is_atom(name), do: GenServer.call(name, message)

  defp start_process(opts) do
    name_opts = if name = Keyword.get(opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  defp current_snapshot(%{catalog_snapshot_mode: :live} = state) do
    upstreams =
      state.upstreams
      |> Map.values()
      |> Enum.map(fn upstream ->
        {upstream, _state} = ensure_upstream_tools(upstream, state)
        upstream
      end)

    upstream_map = Map.new(upstreams, &{&1.name, &1})
    snapshot = scrubbed_snapshot(state.credentials, upstreams)
    {snapshot, %{state | upstreams: upstream_map, snapshot: snapshot}}
  end

  defp current_snapshot(state), do: {state.snapshot, state}

  defp ensure_upstream_tools(%{tools: tools} = upstream, state) when is_list(tools),
    do: {upstream, state}

  defp ensure_upstream_tools(%{transport: :mcp_stdio} = upstream, state) do
    ensure_with(upstream, state, McpStdio)
  end

  defp ensure_upstream_tools(%{transport: :mcp_http} = upstream, state) do
    ensure_with(upstream, state, McpHttp)
  end

  defp ensure_upstream_tools(upstream, state), do: {upstream, state}

  defp ensure_with(upstream, state, module) do
    case ensure_client(upstream, module) do
      {:ok, upstream} ->
        case module.list_tools(upstream) do
          {:ok, tools} ->
            upstream = %{upstream | tools: tools}
            state = put_in(state, [:upstreams, upstream.name], upstream)
            {upstream, state}

          {:error, _reason, _detail} ->
            {upstream, state}
        end

      {:error, _reason, _detail} ->
        {upstream, state}
    end
  end

  defp scrubbed_snapshot(credentials, upstreams) do
    Credentials.scrub(credentials, Catalog.snapshot(upstreams))
  end

  defp maybe_register_redaction_secrets(credentials, opts) do
    case Keyword.get(opts, :redaction_sink) do
      nil ->
        :ok

      {module, function, extra_args}
      when is_atom(module) and is_atom(function) and
             is_list(extra_args) ->
        apply(module, function, [Credentials.redaction_secrets(credentials) | extra_args])

      fun when is_function(fun, 1) ->
        fun.(Credentials.redaction_secrets(credentials))
    end
  end

  defp prepare_upstreams(upstreams, :live) do
    {:ok, Enum.map(upstreams, &mark_lazy_client/1)}
  end

  defp prepare_upstreams(upstreams, _snapshot_mode), do: start_transport_clients(upstreams)

  defp mark_lazy_client(%{transport: transport} = upstream)
       when transport in [:mcp_stdio, :mcp_http] do
    %{upstream | tools: nil}
  end

  defp mark_lazy_client(upstream), do: upstream

  defp start_transport_clients(upstreams) do
    Enum.reduce_while(upstreams, {:ok, []}, fn
      %{transport: :mcp_stdio} = upstream, {:ok, acc} ->
        start_client(upstream, acc, McpStdio)

      %{transport: :mcp_http} = upstream, {:ok, acc} ->
        start_client(upstream, acc, McpHttp)

      upstream, {:ok, acc} ->
        {:cont, {:ok, [upstream | acc]}}
    end)
    |> case do
      {:ok, upstreams} -> {:ok, Enum.reverse(upstreams)}
      err -> err
    end
  end

  defp start_client(upstream, acc, module) do
    case ensure_client(upstream, module) do
      {:ok, upstream} ->
        case module.list_tools(upstream) do
          {:ok, tools} -> {:cont, {:ok, [%{upstream | tools: tools} | acc]}}
          {:error, reason, detail} -> {:halt, {:error, reason, detail}}
        end

      {:error, reason, detail} ->
        {:halt, {:error, reason, detail}}
    end
  end

  defp ensure_client(%{client_pid: pid} = upstream, _module) when is_pid(pid), do: {:ok, upstream}

  defp ensure_client(upstream, module) do
    case module.start_link(upstream.name, upstream.config) do
      {:ok, pid} -> {:ok, Map.put(upstream, :client_pid, pid)}
      {:error, {reason, detail}} -> {:error, reason, detail}
      {:error, reason} -> {:error, :upstream_unavailable, inspect(reason)}
    end
  end
end
