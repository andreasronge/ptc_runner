defmodule PtcGateway.Domain do
  @moduledoc false
  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.{
    GatewayConfig,
    HostConfig,
    HostInstallation,
    InstallationCatalog,
    RunAdmission,
    ServingTemplate,
    WarmProviderRuntime
  }

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def child_spec(args),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}, restart: :temporary}

  @doc "Stable safe tool metadata and listener policy in deterministic name order."
  def metadata(owner), do: GenServer.call(owner, :metadata)

  @doc "The warm runtime owner is the opaque authentication handle."
  def token_handle(owner), do: GenServer.call(owner, :token_handle)

  @impl true
  def init({path, env_file}) do
    Process.flag(:trap_exit, true)

    state = %{
      catalog: nil,
      children: [],
      warm: nil,
      listener: nil,
      request_admission: nil,
      metadata: [],
      policy: nil
    }

    case configure(path, env_file, state) do
      {:ok, ready} ->
        {:ok, ready}

      {:error, code, partial} ->
        cleanup(partial)
        {:stop, code}
    end
  end

  defp configure(path, env_file, state) do
    with {:ok, config} <- GatewayConfig.load(path),
         {:ok, host} <- load_host(config["host"]["path"]),
         :ok <- bearer_binding(host, config["authentication"]["bearer"]["binding"]),
         {:ok, catalog} <- HostInstallation.catalog(host) do
      state = %{
        state
        | catalog: catalog,
          policy: %{listen: config["listen"], admission: config["admission"]}
      }

      with {:ok, tools, metadata} <- templates(config["tools"], host, catalog),
           :ok <- static_catalog(metadata),
           {:ok, services} <- HostInstallation.runtime_services(host) do
        boot(config, tools, services, env_file, %{state | metadata: metadata})
      else
        {:error, code} -> {:error, code, state}
      end
    else
      {:error, code} -> {:error, code, state}
    end
  end

  defp load_host(path) do
    case HostConfig.load(path) do
      {:ok, host} -> {:ok, host}
      _ -> {:error, :host_invalid}
    end
  end

  # The bearer is a binding the host resolves once inside the env-file scope.
  # A literal credential would keep the token in the host document itself,
  # outside that scope and outside the opaque owner, so it is refused before
  # any child starts. An unknown binding refuses here with the same closed code
  # that capture would raise later.
  defp bearer_binding(host, binding) do
    case host.credentials[binding] do
      %{source: source} when source != :literal -> :ok
      _ -> {:error, :credential_unavailable}
    end
  end

  defp templates(entries, host, catalog) do
    Enum.reduce_while(entries, {:ok, %{}, []}, fn entry, {:ok, tools, metadata} ->
      case template(entry, host, catalog) do
        {:ok, template} ->
          pins = %{
            installation_config_pins: entry["installation_config_pins"],
            provider_snapshot_pins: entry["provider_snapshot_pins"]
          }

          safe = %{
            "name" => entry["name"],
            "title" => entry["title"],
            "description" => entry["description"],
            "inputSchema" => ServingTemplate.input_schema(template),
            "outputSchema" => ServingTemplate.output_schema(template),
            "annotations" => %{"readOnlyHint" => ServingTemplate.effect(template) == :read}
          }

          {:cont,
           {:ok, Map.put(tools, entry["name"], %{template: template, pins: pins}),
            metadata ++ [safe]}}

        {:error, code} ->
          {:halt, {:error, code}}
      end
    end)
  end

  defp static_catalog(tools) do
    schemas = Enum.flat_map(tools, &[&1["inputSchema"], &1["outputSchema"]])

    listing = %{
      "jsonrpc" => "2.0",
      "id" => String.duplicate("x", 256),
      "result" => %{
        "resultType" => "complete",
        "tools" => tools,
        "ttlMs" => 0,
        "cacheScope" => "private"
      }
    }

    if Enum.all?(schemas, &(encoded_size(&1) <= 65_536)) and
         encoded_size(tools) <= 4_194_304 and encoded_size(listing) <= 4_194_304,
       do: :ok,
       else: {:error, :static_catalog_too_large}
  end

  defp encoded_size(value) do
    case PtcRunner.Kernel.DeterministicJSON.encode(value) do
      {:ok, bytes} -> byte_size(bytes)
      _ -> 4_194_305
    end
  end

  defp template(entry, host, catalog) do
    case ServingTemplate.from_directory(entry["application"]["manifest"], host.limits,
           providers: catalog,
           expected_application_content_digest: entry["expected_application_content_digest"]
         ) do
      {:ok, template} ->
        if ServingTemplate.effect(template) == :write and not entry["allow_write"],
          do: {:error, :write_forbidden},
          else: {:ok, template}

      {:error, %{code: :application_content_digest_mismatch}} ->
        {:error, :application_content_digest_mismatch}

      {:error, :application_content_digest_mismatch} ->
        {:error, :application_content_digest_mismatch}

      _ ->
        {:error, :template_invalid}
    end
  end

  defp boot(config, tools, services, env_file, state) do
    case audit(config) do
      {:ok, audit} -> start_run(config, tools, services, env_file, child(state, audit))
      _ -> {:error, :audit_unavailable, state}
    end
  end

  defp audit(%{"private_audit" => config}), do: PtcGateway.PrivateAudit.start_link(config)
  defp audit(_), do: {:ok, nil}

  defp start_run(config, tools, services, env_file, state) do
    admission = config["admission"]

    case RunAdmission.start_link(max_concurrent_runs: admission["max_concurrent_runs"]) do
      {:ok, run} ->
        state = child(state, run)

        case WarmProviderRuntime.start_link(
               tools: tools,
               services: services,
               bearer_binding: config["authentication"]["bearer"]["binding"],
               run_admission: run,
               max_active_provider_calls: admission["max_active_provider_calls"],
               max_waiting_provider_calls: admission["max_waiting_provider_calls"],
               env_file: env_file
             ) do
          {:ok, warm} -> start_request_admission(config, %{child(state, warm) | warm: warm})
          {:error, code} -> {:error, PtcGateway.StartupError.normalize(code), state}
        end

      _ ->
        {:error, :run_admission_unavailable, state}
    end
  end

  defp start_request_admission(config, state) do
    case PtcGateway.RequestAdmission.start_link(config["admission"]["max_inflight_requests"]) do
      {:ok, admission} ->
        listen(config, %{child(state, admission) | request_admission: admission})

      _ ->
        {:error, :run_admission_unavailable, state}
    end
  end

  defp listen(config, state) do
    listen = config["listen"]
    ip = if listen["address"] == "::1", do: {0, 0, 0, 0, 0, 0, 0, 1}, else: {127, 0, 0, 1}

    case Bandit.start_link(
           plug:
             {PtcGateway.Router,
              listen: listen,
              warm: state.warm,
              tools: state.metadata,
              request_admission: state.request_admission},
           ip: ip,
           port: listen["port"],
           startup_log: false,
           http_options: [
             log_protocol_errors: false,
             log_exceptions_with_status_codes: [],
             log_client_closures: false
           ],
           http_1_options: [max_header_length: 8_192, max_header_count: 64],
           http_2_options: [enabled: false]
         ) do
      {:ok, listener} -> {:ok, %{child(state, listener) | listener: listener}}
      _ -> {:error, :listener_unavailable, state}
    end
  end

  defp child(state, nil), do: state
  defp child(state, pid), do: %{state | children: [pid | state.children]}

  @impl true
  def handle_call(:metadata, _, state),
    do: {:reply, %{tools: state.metadata, listener_policy: state.policy}, state}

  def handle_call(:token_handle, _, state), do: {:reply, state.warm, state}

  @impl true
  def handle_info({:EXIT, pid, _}, %{listener: pid} = state), do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, reason}, state) do
    if is_pid(state.warm) and (pid in state.children or reason != :normal),
      do: WarmProviderRuntime.drain(state.warm, System.monotonic_time(:millisecond))

    {:noreply, state}
  end

  @impl true
  def terminate(_, state), do: cleanup(state)

  defp cleanup(state) do
    if is_pid(state.listener) and Process.alive?(state.listener), do: stop(state.listener)

    if is_pid(state.warm),
      do: WarmProviderRuntime.drain(state.warm, System.monotonic_time(:millisecond))

    for pid <- state.children, Process.alive?(pid), do: stop(pid)
    if state.catalog, do: InstallationCatalog.close(state.catalog)
    :ok
  end

  defp stop(pid) do
    GenServer.stop(pid, :shutdown)
  catch
    :exit, _ -> :ok
  end
end
