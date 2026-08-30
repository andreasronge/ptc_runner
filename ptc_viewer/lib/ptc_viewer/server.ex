defmodule PtcViewer.Server do
  @moduledoc false

  use GenServer

  alias PtcViewer.OwnerStatusRedaction

  alias PtcViewer.InspectionStore
  alias PtcViewer.LiveSecurity
  alias PtcViewer.ReplConnection
  alias PtcViewer.ReplStore

  @shutdown_timeout_ms 30_000
  @loopback {127, 0, 0, 1}
  # Closed, so a typo cannot become a different exposure. The wildcard exists
  # for one reason: inside a container it is the only address a published port
  # can forward to, and the host exposure decision moves to the publish rule.
  @addresses [@loopback, {0, 0, 0, 0}]

  def start(opts), do: GenServer.start(__MODULE__, opts)
  def stop(pid), do: GenServer.call(pid, :stop, @shutdown_timeout_ms + 5_000)
  def listener_info(pid), do: GenServer.call(pid, :listener_info)
  def expected_port(pid), do: GenServer.call(pid, :expected_port)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    port = Keyword.get(opts, :port, 0)
    ip = Keyword.get(opts, :ip, @loopback)
    trace_dir = opts |> Keyword.get(:trace_dir, "traces") |> Path.expand()
    kernel_adapter = Keyword.get(opts, :kernel_trace_adapter)
    inspection_file = Keyword.get(opts, :inspection_file)
    inspection_adapter = Keyword.get(opts, :inspection_adapter)
    inspection_absence = Keyword.get(opts, :inspection_absence)
    repl_adapter = Keyword.get(opts, :repl_adapter)
    repl_config = Keyword.get(opts, :repl_config, %{})
    private_traces = Keyword.get(opts, :private_traces, false) == true
    trace_source = Keyword.get(opts, :trace_source)
    inspection_source = Keyword.get(opts, :inspection_source)
    launch = Keyword.get(opts, :launch)
    project_adapter = Keyword.get(opts, :project_adapter)
    live_trace_refresh = Keyword.get(opts, :live_trace_refresh)
    live_token = Keyword.get(opts, :live_token)
    live_mutation_nonce = LiveSecurity.nonce()

    if is_integer(port) and port in 0..65_535 and ip in @addresses and
         PtcViewer.LiveLaunch.validate(launch) == :ok and
         PtcViewer.LiveProject.validate(project_adapter) == :ok and
         valid_trace_refresh?(live_trace_refresh) and
         LiveSecurity.validate_token(live_token) == :ok do
      params = %{
        port: port,
        ip: ip,
        trace_dir: trace_dir,
        kernel_adapter: kernel_adapter,
        inspection_file: inspection_file,
        inspection_adapter: inspection_adapter,
        inspection_absence: inspection_absence,
        repl_adapter: repl_adapter,
        repl_config: repl_config,
        private_traces: private_traces,
        trace_source: trace_source,
        inspection_source: inspection_source,
        launch: launch,
        project_adapter: project_adapter,
        live_trace_refresh: live_trace_refresh,
        live_token: live_token,
        live_mutation_nonce: live_mutation_nonce
      }

      case start_resources(params) do
        {:ok, state} ->
          maybe_open(Keyword.get(opts, :open, true), state.listener_info)
          {:ok, state}

        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:stop, :invalid_viewer_config}
    end
  end

  defp start_resources(params) do
    case pin_inspection_source(params) do
      {:ok, inspection_store} -> start_connection(params, inspection_store)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_connection(params, inspection_store) do
    case connect_repl(params.repl_adapter, params.repl_config) do
      {:ok, connection} ->
        start_repl_runtime(params, inspection_store, connection)

      {:error, reason} ->
        stop_inspection_store(inspection_store)
        {:error, reason}
    end
  end

  defp start_repl_runtime(params, inspection_store, nil) do
    start_bandit(params, inspection_store, nil, nil, nil)
  end

  defp start_repl_runtime(params, inspection_store, connection) do
    case Task.Supervisor.start_link() do
      {:ok, task_supervisor} ->
        case start_repl_store(connection, params.repl_adapter, task_supervisor) do
          {:ok, repl_store} ->
            start_bandit(params, inspection_store, connection, task_supervisor, repl_store)

          {:error, reason} ->
            stop_task_supervisor(task_supervisor)
            stop_connection(connection)
            stop_inspection_store(inspection_store)
            {:error, reason}
        end

      {:error, _reason} ->
        stop_connection(connection)
        stop_inspection_store(inspection_store)
        {:error, :repl_connection_failed}
    end
  end

  defp start_bandit(params, inspection_store, connection, task_supervisor, repl_store) do
    # Bound to this server by monitor: any server exit stops the store, so no
    # cleanup threading is needed on the error paths below.
    {:ok, live_store} = PtcViewer.LiveStore.start(self())

    config =
      router_config(
        params,
        inspection_store,
        repl_store,
        live_store,
        self()
      )

    case Bandit.start_link(
           plug: {PtcViewer.Router, config},
           port: params.port,
           ip: params.ip
         ) do
      {:ok, bandit} ->
        Process.unlink(bandit)
        start_bandit_guard(self(), bandit)
        if connection, do: ReplConnection.attach_child(connection, bandit)

        finish_bandit_start(
          bandit,
          inspection_store,
          connection,
          task_supervisor,
          repl_store
        )

      {:error, _reason} ->
        cleanup_resources(inspection_store, connection, task_supervisor, repl_store, nil)
        {:error, :viewer_start_failed}
    end
  end

  defp finish_bandit_start(bandit, inspection_store, connection, task_supervisor, repl_store) do
    with {:ok, listener_info} <- ThousandIsland.listener_info(bandit),
         :ok <- attach_inspection_store(inspection_store, self()) do
      {:ok,
       %{
         bandit: bandit,
         bandit_ref: Process.monitor(bandit),
         connection: connection,
         inspection_store: inspection_store,
         listener_info: listener_info,
         repl_store: repl_store,
         repl_store_ref: monitor(repl_store),
         task_supervisor: task_supervisor
       }}
    else
      {:error, reason} ->
        cleanup_resources(inspection_store, connection, task_supervisor, repl_store, bandit)
        {:error, reason}
    end
  end

  @impl GenServer
  def handle_call(:listener_info, _from, state), do: {:reply, {:ok, state.listener_info}, state}
  def handle_call(:expected_port, _from, state), do: {:reply, elem(state.listener_info, 1), state}

  def handle_call(:stop, _from, state) do
    stop_bandit(state.bandit)
    result = shutdown_repl(state.repl_store)
    {:stop, :normal, result, %{state | bandit: nil}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{bandit_ref: ref} = state) do
    {:stop, :viewer_listener_failed, %{state | bandit: nil, bandit_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{repl_store_ref: ref} = state) do
    stop_bandit(state.bandit)
    {:stop, :repl_store_failed, %{state | bandit: nil, repl_store: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{connection: %{ref: ref}} = state) do
    stop_bandit(state.bandit)
    {:stop, :repl_backend_failed, %{state | bandit: nil, connection: nil}}
  end

  def handle_info({:EXIT, pid, _reason}, %{repl_store: pid} = state) do
    stop_bandit(state.bandit)
    {:stop, :repl_store_failed, %{state | bandit: nil, repl_store: nil}}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    if pid in [state.bandit, state.task_supervisor, state.repl_store] and reason != :normal do
      stop_bandit(state.bandit)
      {:stop, :viewer_child_failed, %{state | bandit: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: OwnerStatusRedaction.format(status)
  else
    def format_status(status), do: OwnerStatusRedaction.format(status)
  end

  @impl GenServer
  def format_status(reason, status), do: OwnerStatusRedaction.format(reason, status)

  @impl GenServer
  def terminate(_reason, state) do
    stop_bandit(state.bandit)
    stop_store(state.repl_store)
    stop_task_supervisor(state.task_supervisor)
    stop_connection(state.connection)
    stop_inspection_store(state.inspection_store)
    :ok
  end

  defp connect_repl(nil, _config), do: {:ok, nil}

  defp connect_repl(adapter, config) when is_atom(adapter) and is_map(config),
    do: ReplConnection.start(adapter, config)

  defp connect_repl(_adapter, _config), do: {:error, :invalid_repl_config}

  defp start_repl_store(%ReplConnection{} = connection, adapter, task_supervisor) do
    ReplStore.start_link(
      owner: self(),
      task_supervisor: task_supervisor,
      adapter: adapter,
      backend: connection.backend,
      features: connection.features
    )
  end

  defp router_config(params, inspection_store, repl_store, live_store, server) do
    [
      trace_dir: params.trace_dir,
      private_traces: params.private_traces,
      trace_source: params.trace_source,
      kernel_trace_adapter: params.kernel_adapter,
      inspection_store: inspection_store,
      inspection_adapter: params.inspection_adapter,
      inspection_absence: params.inspection_absence,
      repl_store: repl_store,
      repl_enabled: not is_nil(repl_store),
      live_store: live_store,
      live_launch: params.launch,
      live_project: params.project_adapter,
      live_trace_refresh: params.live_trace_refresh,
      live_token_digest: LiveSecurity.token_digest(params.live_token),
      live_mutation_nonce: params.live_mutation_nonce,
      viewer_server: server
    ]
  end

  defp trace_source(%{private_traces: true, trace_dir: trace_dir}),
    do: {:private_directory, trace_dir}

  defp trace_source(%{trace_dir: trace_dir}), do: {:directory, trace_dir}

  defp valid_trace_refresh?(nil), do: true
  defp valid_trace_refresh?(callback), do: is_function(callback, 1)

  defp pin_inspection_source(%{inspection_source: source}) when not is_nil(source),
    do: InspectionStore.start(source)

  defp pin_inspection_source(params),
    do: pin_inspection(params.inspection_file, params.inspection_adapter, trace_source(params))

  defp pin_inspection(nil, nil, _trace_source), do: {:ok, nil}

  defp pin_inspection(path, nil, _trace_dir) when is_binary(path),
    do: {:error, :invalid_inspection_config}

  defp pin_inspection(path, adapter, trace_source) when is_binary(path) and is_atom(adapter) do
    if valid_inspection_adapter?(adapter) do
      with {:ok, source} <-
             adapter
             |> apply(:pin_inspection, [Path.expand(path), trace_source])
             |> normalize_pin_result(),
           {:ok, store} <- InspectionStore.start(source) do
        {:ok, store}
      end
    else
      {:error, :invalid_inspection_adapter}
    end
  rescue
    _exception -> {:error, :inspection_adapter_failure}
  catch
    _kind, _reason -> {:error, :inspection_adapter_failure}
  end

  defp pin_inspection(_path, _adapter, _trace_dir), do: {:error, :invalid_inspection_config}

  defp valid_inspection_adapter?(adapter) do
    Code.ensure_loaded?(adapter) and
      Enum.all?(
        [
          :pin_inspection,
          :conversation,
          :preludes,
          :execution_errors,
          :explicit_failure_values
        ],
        fn operation ->
          function_exported?(adapter, operation, 2)
        end
      )
  end

  defp normalize_pin_result({:ok, source}) when not is_nil(source), do: {:ok, source}
  defp normalize_pin_result({:error, reason}) when is_atom(reason), do: {:error, reason}

  defp normalize_pin_result(_invalid), do: {:error, :inspection_adapter_failure}

  defp attach_inspection_store(nil, _owner), do: :ok
  defp attach_inspection_store(store, owner), do: InspectionStore.attach(store, owner)

  defp monitor(nil), do: nil
  defp monitor(pid), do: Process.monitor(pid)

  defp shutdown_repl(nil), do: :ok

  defp shutdown_repl(store) do
    ReplStore.shutdown(store, @shutdown_timeout_ms)
  catch
    :exit, _reason -> {:error, :adapter_failure}
  end

  defp stop_bandit(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  defp stop_bandit(_pid), do: :ok

  defp stop_store(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  defp stop_store(_pid), do: :ok

  defp stop_task_supervisor(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  defp stop_task_supervisor(_pid), do: :ok

  defp stop_connection(nil), do: :ok
  defp stop_connection(connection), do: ReplConnection.stop(connection)

  defp stop_inspection_store(pid) when is_pid(pid) do
    if Process.alive?(pid), do: InspectionStore.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp stop_inspection_store(_pid), do: :ok

  defp cleanup_resources(inspection_store, connection, task_supervisor, repl_store, bandit) do
    stop_bandit(bandit)
    stop_store(repl_store)
    stop_task_supervisor(task_supervisor)
    stop_connection(connection)
    stop_inspection_store(inspection_store)
    :ok
  end

  defp maybe_open(false, _listener_info), do: :ok

  defp maybe_open(true, {_address, port}) do
    case browser_opener() do
      nil -> :ok
      opener -> run_opener(opener, "http://localhost:#{port}")
    end
  end

  defp browser_opener do
    executable =
      case :os.type() do
        {:unix, :darwin} -> "open"
        {:unix, _name} -> "xdg-open"
        _other -> nil
      end

    if executable, do: System.find_executable(executable), else: nil
  end

  defp run_opener(opener, url) do
    task = Task.async(fn -> System.cmd(opener, [url], stderr_to_stdout: true) end)

    case Task.yield(task, 2_000) do
      {:ok, _result} -> :ok
      {:exit, _reason} -> :ok
      nil -> Task.shutdown(task, :brutal_kill)
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp start_bandit_guard(owner, bandit) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      bandit_ref = Process.monitor(bandit)

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _reason} -> stop_bandit(bandit)
        {:DOWN, ^bandit_ref, :process, ^bandit, _reason} -> :ok
      end
    end)

    :ok
  end
end
