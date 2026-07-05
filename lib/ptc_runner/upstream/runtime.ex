defmodule PtcRunner.Upstream.Runtime do
  @moduledoc """
  OTP-backed upstream runtime handle for root `ptc_runner` callers.
  """

  use GenServer

  alias PtcRunner.Upstream.{Catalog, Config, Credentials, OpenAPI}
  alias PtcRunner.Upstream.Transport.McpHttp
  alias PtcRunner.Upstream.Transport.McpStdio

  defstruct [
    :pid,
    :catalog_exposure_mode,
    :catalog_snapshot_mode,
    :credential_grants,
    :upstream_tool_grants
  ]

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

  @spec defaults(struct() | pid()) :: map()
  def defaults(runtime), do: call(runtime, :defaults)

  @spec project(struct() | pid(), keyword()) :: {:ok, struct()} | {:error, String.t()}
  def project(runtime, opts) do
    credential_grants = Keyword.get(opts, :credential_grants, credential_grants(runtime))
    upstream_tool_grants = Keyword.get(opts, :upstream_tool_grants, upstream_tool_grants(runtime))

    with {:ok, credential_grants} <- normalize_credential_grants(credential_grants),
         {:ok, upstream_tool_grants} <- normalize_upstream_tool_grants(upstream_tool_grants),
         :ok <- validate_credential_projection_narrows(runtime, credential_grants),
         :ok <- validate_upstream_tool_projection_narrows(runtime, upstream_tool_grants),
         :ok <- call(runtime, {:validate_credential_grants, credential_grants}) do
      {:ok,
       %__MODULE__{
         pid: runtime_pid(runtime),
         catalog_exposure_mode: catalog_exposure_mode(runtime),
         catalog_snapshot_mode: catalog_snapshot_mode(runtime),
         credential_grants: credential_grants,
         upstream_tool_grants: upstream_tool_grants
       }}
    end
  end

  @spec credential_binding_names(struct() | pid()) :: [String.t()]
  def credential_binding_names(runtime), do: call(runtime, :credential_binding_names)

  @spec credential_grants(struct() | pid()) :: :all | MapSet.t()
  def credential_grants(%__MODULE__{credential_grants: nil}), do: :all
  def credential_grants(%__MODULE__{credential_grants: grants}), do: grants
  def credential_grants(_runtime), do: :all

  @spec upstream(struct() | pid(), String.t()) :: map() | nil
  def upstream(runtime, name), do: call(runtime, {:upstream, name})

  @spec upstream_names(struct() | pid()) :: [String.t()]
  def upstream_names(runtime), do: call(runtime, :upstream_names)

  @spec upstream_tool_allowed?(struct() | pid(), String.t(), String.t()) :: boolean()
  def upstream_tool_allowed?(%__MODULE__{upstream_tool_grants: grants}, server, tool)
      when is_binary(server) and is_binary(tool) do
    upstream_tool_granted?(grants, server, tool)
  end

  def upstream_tool_allowed?(_runtime, _server, _tool), do: true

  @spec upstream_tool_grants(struct() | pid()) :: :all | MapSet.t()
  def upstream_tool_grants(%__MODULE__{upstream_tool_grants: nil}), do: :all
  def upstream_tool_grants(%__MODULE__{upstream_tool_grants: grants}), do: grants
  def upstream_tool_grants(_runtime), do: :all

  @spec constrain_upstream_tool_grants(struct() | pid(), :all | MapSet.t() | [String.t()]) ::
          {:ok, :all | MapSet.t()} | {:error, String.t()}
  def constrain_upstream_tool_grants(runtime, requested) do
    with {:ok, requested} <- normalize_upstream_tool_grants(requested),
         :ok <- validate_upstream_tool_projection_narrows(runtime, requested) do
      {:ok, requested}
    end
  end

  @spec call_tool(struct() | pid(), String.t(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, atom(), String.t()}
  def call_tool(runtime, server, tool, args, opts) do
    if upstream_tool_allowed?(runtime, server, tool) do
      dispatch_call_tool(runtime, server, tool, args, opts)
    else
      {:error, :upstream_tool_denied,
       "upstream operation #{server}/#{tool} is not granted for this run"}
    end
  end

  defp dispatch_call_tool(runtime, server, tool, args, opts) do
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

  @spec catalog_snapshot(struct() | pid(), keyword()) :: [map()]
  def catalog_snapshot(runtime, opts \\ []) do
    if Keyword.get(opts, :materialize, true) do
      call(runtime, :catalog_snapshot)
    else
      call(runtime, :configured_catalog_snapshot)
    end
  end

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

  def handle_call(:credential_binding_names, _from, state),
    do: {:reply, Credentials.binding_names(state.credentials) |> Enum.sort(), state}

  def handle_call({:validate_credential_grants, grants}, _from, state) do
    reply =
      case Credentials.subset(state.credentials, grants) do
        {:ok, _credentials} -> :ok
        {:error, message} -> {:error, message}
      end

    {:reply, reply, state}
  end

  def handle_call(:upstream_names, _from, state),
    do: {:reply, Map.keys(state.upstreams) |> Enum.sort(), state}

  def handle_call(
        {:projected, _credential_grants, _upstream_tool_grants, :defaults},
        _from,
        state
      ),
      do: {:reply, state.defaults, state}

  def handle_call(
        {:projected, _credential_grants, _upstream_tool_grants, :upstream_names},
        _from,
        state
      ),
      do: {:reply, Map.keys(state.upstreams) |> Enum.sort(), state}

  def handle_call(
        {:projected, credential_grants, upstream_tool_grants, {:upstream, name}},
        _from,
        state
      ) do
    case Map.get(state.upstreams, name) do
      nil ->
        {:reply, nil, state}

      upstream ->
        {upstream, state} =
          projected_upstream_with_tools(upstream, state, credential_grants, upstream_tool_grants)

        {:reply, upstream, state}
    end
  end

  def handle_call(
        {:projected, credential_grants, upstream_tool_grants, :catalog_snapshot},
        _from,
        state
      ) do
    {snapshot, state} = current_projected_snapshot(state, credential_grants, upstream_tool_grants)
    {:reply, snapshot, state}
  end

  def handle_call(
        {:projected, credential_grants, upstream_tool_grants, :configured_catalog_snapshot},
        _from,
        state
      ) do
    snapshot = configured_projected_snapshot(state, credential_grants, upstream_tool_grants)
    {:reply, snapshot, state}
  end

  def handle_call(
        {:projected, credential_grants, upstream_tool_grants, :catalog_text},
        _from,
        state
      ) do
    {snapshot, state} = current_projected_snapshot(state, credential_grants, upstream_tool_grants)

    text =
      Catalog.render_text(snapshot, state.catalog_exposure_mode,
        catalog_inline_max_chars: state.catalog_inline_max_chars,
        catalog_inline_max_tools: state.catalog_inline_max_tools
      )

    {:reply, text, state}
  end

  def handle_call(
        {:projected, _credential_grants, _upstream_tool_grants, {:scrub, term}},
        _from,
        state
      ),
      do: {:reply, Credentials.scrub(state.credentials, term), state}

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

  def handle_call(:configured_catalog_snapshot, _from, state) do
    snapshot = scrubbed_snapshot(state.credentials, Map.values(state.upstreams))
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

  defp call(
         %__MODULE__{
           pid: pid,
           credential_grants: credential_grants,
           upstream_tool_grants: upstream_tool_grants
         },
         message
       )
       when credential_grants != nil or upstream_tool_grants != nil do
    if projected_message?(message) do
      GenServer.call(
        pid,
        {:projected, credential_grants || :all, upstream_tool_grants || :all, message}
      )
    else
      GenServer.call(pid, message)
    end
  end

  defp call(%__MODULE__{pid: pid}, message), do: GenServer.call(pid, message)
  defp call(pid, message) when is_pid(pid), do: GenServer.call(pid, message)
  defp call(name, message) when is_atom(name), do: GenServer.call(name, message)

  defp projected_message?(:defaults), do: true
  defp projected_message?(:upstream_names), do: true
  defp projected_message?(:catalog_snapshot), do: true
  defp projected_message?(:configured_catalog_snapshot), do: true
  defp projected_message?(:catalog_text), do: true
  defp projected_message?({:upstream, _name}), do: true
  defp projected_message?({:scrub, _term}), do: true
  defp projected_message?(_message), do: false

  defp runtime_pid(%__MODULE__{pid: pid}), do: pid
  defp runtime_pid(pid) when is_pid(pid), do: pid

  defp catalog_exposure_mode(%__MODULE__{catalog_exposure_mode: mode}), do: mode
  defp catalog_exposure_mode(_runtime), do: :auto

  defp catalog_snapshot_mode(%__MODULE__{catalog_snapshot_mode: mode}), do: mode
  defp catalog_snapshot_mode(_runtime), do: :live

  defp normalize_credential_grants(:all), do: {:ok, :all}

  defp normalize_credential_grants(%MapSet{} = grants) do
    if Enum.all?(grants, &(is_binary(&1) and &1 != "")) do
      {:ok, grants}
    else
      {:error, "credential grants must be non-empty strings"}
    end
  end

  defp normalize_credential_grants(grants) when is_list(grants) do
    normalize_credential_grants(MapSet.new(grants))
  end

  defp normalize_credential_grants(_grants),
    do: {:error, "credential_grants must be :all or strings"}

  defp normalize_upstream_tool_grants(:all), do: {:ok, :all}

  defp normalize_upstream_tool_grants(%MapSet{} = grants) do
    if Enum.all?(grants, &valid_upstream_tool_grant?/1) do
      {:ok, grants}
    else
      {:error, "upstream_tool_grants must use upstream:<server>/<tool> strings"}
    end
  end

  defp normalize_upstream_tool_grants(grants) when is_list(grants) do
    normalize_upstream_tool_grants(MapSet.new(grants))
  end

  defp normalize_upstream_tool_grants(_grants),
    do: {:error, "upstream_tool_grants must be :all or upstream:<server>/<tool> strings"}

  defp valid_upstream_tool_grant?("upstream:" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [server, tool] when server != "" and tool != "" -> true
      _ -> false
    end
  end

  defp valid_upstream_tool_grant?(_value), do: false

  defp validate_credential_projection_narrows(%__MODULE__{credential_grants: nil}, _requested),
    do: :ok

  defp validate_credential_projection_narrows(%__MODULE__{credential_grants: :all}, _requested),
    do: :ok

  defp validate_credential_projection_narrows(%__MODULE__{credential_grants: current}, :all)
       when current not in [nil, :all],
       do: {:error, "credential grants cannot expand a projected runtime"}

  defp validate_credential_projection_narrows(_runtime, :all), do: :ok

  defp validate_credential_projection_narrows(
         %__MODULE__{credential_grants: current},
         requested
       )
       when is_struct(current, MapSet) and is_struct(requested, MapSet) do
    if MapSet.subset?(requested, current) do
      :ok
    else
      {:error, "credential grants cannot expand a projected runtime"}
    end
  end

  defp validate_credential_projection_narrows(_runtime, _requested), do: :ok

  defp validate_upstream_tool_projection_narrows(
         %__MODULE__{upstream_tool_grants: nil},
         _requested
       ),
       do: :ok

  defp validate_upstream_tool_projection_narrows(
         %__MODULE__{upstream_tool_grants: :all},
         _requested
       ),
       do: :ok

  defp validate_upstream_tool_projection_narrows(
         %__MODULE__{upstream_tool_grants: current},
         :all
       )
       when current not in [nil, :all],
       do: {:error, "upstream tool grants cannot expand a projected runtime"}

  defp validate_upstream_tool_projection_narrows(_runtime, :all), do: :ok

  defp validate_upstream_tool_projection_narrows(
         %__MODULE__{upstream_tool_grants: current},
         requested
       )
       when is_struct(current, MapSet) and is_struct(requested, MapSet) do
    if MapSet.subset?(requested, current) do
      :ok
    else
      {:error, "upstream tool grants cannot expand a projected runtime"}
    end
  end

  defp validate_upstream_tool_projection_narrows(_runtime, _requested), do: :ok

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

  defp current_projected_snapshot(
         %{catalog_snapshot_mode: :live} = state,
         credential_grants,
         upstream_tool_grants
       ) do
    {upstreams, state} =
      state.upstreams
      |> Map.values()
      |> Enum.reduce({[], state}, fn upstream, {acc, state} ->
        {upstream, state} =
          projected_upstream_with_tools(
            upstream,
            state,
            credential_grants,
            upstream_tool_grants
          )

        {[upstream | acc], state}
      end)

    snapshot = scrubbed_snapshot(state.credentials, Enum.reverse(upstreams))
    {snapshot, state}
  end

  defp current_projected_snapshot(state, credential_grants, upstream_tool_grants) do
    {configured_projected_snapshot(state, credential_grants, upstream_tool_grants), state}
  end

  defp configured_projected_snapshot(state, credential_grants, upstream_tool_grants) do
    upstreams =
      state.upstreams
      |> Map.values()
      |> Enum.map(fn upstream ->
        upstream
        |> project_upstream(state.credentials, credential_grants)
        |> filter_upstream_tools(upstream_tool_grants)
      end)

    scrubbed_snapshot(state.credentials, upstreams)
  end

  defp projected_upstream_with_tools(upstream, state, credential_grants, upstream_tool_grants) do
    if root_client_reusable_before_projection?(upstream, credential_grants) do
      {upstream, state} = ensure_upstream_tools(upstream, state)

      upstream =
        upstream
        |> project_upstream(state.credentials, credential_grants)
        |> filter_upstream_tools(upstream_tool_grants)

      {upstream, state}
    else
      upstream =
        upstream
        |> project_upstream(state.credentials, credential_grants)
        |> filter_upstream_tools(upstream_tool_grants)

      {upstream, _state} = ensure_upstream_tools(upstream, state)
      {filter_upstream_tools(upstream, upstream_tool_grants), state}
    end
  end

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

  defp project_upstream(upstream, _credentials, :all), do: upstream

  defp project_upstream(%{transport: :openapi, config: config} = upstream, credentials, grants)
       when is_map(config) do
    put_projected_credentials(upstream, credentials, grants)
  end

  defp project_upstream(%{transport: :mcp_http, config: config} = upstream, credentials, grants)
       when is_map(config) do
    if auth_bindings_granted?(Map.get(config, :auth, []), grants) do
      put_projected_credentials(upstream, credentials, grants)
    else
      upstream
      |> Map.delete(:client_pid)
      |> Map.put(:tools, nil)
      |> put_projected_credentials(credentials, grants)
    end
  end

  defp project_upstream(%{transport: :mcp_stdio} = upstream, _credentials, _grants), do: upstream

  defp project_upstream(%{config: config} = upstream, credentials, grants) when is_map(config) do
    put_projected_credentials(upstream, credentials, grants)
  end

  defp project_upstream(upstream, _credentials, _grants), do: upstream

  defp filter_upstream_tools(upstream, :all), do: upstream

  defp filter_upstream_tools(%{tools: tools, name: server} = upstream, grants)
       when is_list(tools) and is_struct(grants, MapSet) do
    tools =
      Enum.filter(tools, fn tool ->
        name = Map.get(tool, "name")
        is_binary(name) and upstream_tool_granted?(grants, server, name)
      end)

    Map.put(upstream, :tools, tools)
  end

  defp filter_upstream_tools(upstream, _grants), do: upstream

  defp upstream_tool_granted?(nil, _server, _tool), do: true
  defp upstream_tool_granted?(:all, _server, _tool), do: true

  defp upstream_tool_granted?(grants, server, tool)
       when is_struct(grants, MapSet) and is_binary(server) and is_binary(tool) do
    MapSet.member?(grants, "upstream:#{server}/#{tool}")
  end

  defp upstream_tool_granted?(_grants, _server, _tool), do: false

  defp root_client_reusable_before_projection?(%{transport: :mcp_stdio}, _grants), do: true

  defp root_client_reusable_before_projection?(%{transport: :mcp_http, config: config}, grants)
       when is_map(config) do
    auth_bindings_granted?(Map.get(config, :auth, []), grants)
  end

  defp root_client_reusable_before_projection?(_upstream, _grants), do: false

  defp put_projected_credentials(%{config: config} = upstream, credentials, grants)
       when is_map(config) do
    case Credentials.subset(credentials, grants) do
      {:ok, projected_credentials} ->
        put_in(upstream, [:config, :credentials], projected_credentials)

      {:error, _message} ->
        put_in(upstream, [:config, :credentials], %Credentials{missing_detail: :generic})
    end
  end

  defp auth_bindings_granted?(emitters, grants) when is_list(emitters) do
    emitters
    |> Enum.map(&Map.get(&1, "binding"))
    |> Enum.reject(&is_nil/1)
    |> Enum.all?(fn binding -> grants == :all or MapSet.member?(grants, binding) end)
  end

  defp auth_bindings_granted?(_emitters, _grants), do: false

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
