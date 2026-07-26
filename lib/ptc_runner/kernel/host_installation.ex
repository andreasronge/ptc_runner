defmodule PtcRunner.Kernel.HostInstallation do
  @moduledoc """
  Turns one strict host document into a staged provider registry.

  The returned registry contains exactly the aliases installed by the host
  document. Manifest selections cannot fall back to the legacy implicit
  built-ins. MCP installations prepare selection and placement without I/O,
  preflight local executable and launcher identity without reading
  credentials, and only then render the once-resolved credentials while
  acquiring the transport and catalog. Live LLM installations use the same
  barrier: model resolution precedes credential access, while the acquired
  capability receives its key explicitly and records only non-secret model
  policy in a deterministic provider snapshot.
  """

  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.ProviderRegistry

  @compatibility_environment ~w(HOME LOGNAME PATH SHELL TERM USER)
  @max_credential_bytes 65_536
  @max_executable_bytes 268_435_456
  @max_launcher_bytes 16_777_216
  @launcher_protocol_version 1

  @doc "Builds the closed provider registry installed by a loaded host document."
  @spec registry(HostConfig.t()) ::
          {:ok, ProviderRegistry.t()} | {:error, :invalid_host_installation}
  def registry(%HostConfig{} = host) do
    builders =
      Map.new(host.install, fn {name, installation} ->
        prepare = fn selection, context ->
          prepare(host, installation, selection, context)
        end

        {name, ProviderRegistry.staged(prepare)}
      end)

    case ProviderRegistry.new(builders,
           credential_resolver: &resolve_credentials(host, &1)
         ) do
      {:ok, registry} -> {:ok, registry}
      {:error, _reason} -> {:error, :invalid_host_installation}
    end
  end

  def registry(_host), do: {:error, :invalid_host_installation}

  defp prepare(host, %{source: :mcp} = installation, selection, context) do
    with :ok <- placement(installation, context.destination),
         {:ok, selected} <- mcp_selection(installation, selection, context) do
      credential_names = credential_names(installation.transport)

      {:ok,
       %{
         credential_names: credential_names,
         data_class: installation.data_class,
         accepts_data: installation.accepts_data,
         preflight: fn ->
           with {:ok, transport} <- preflight_transport(host, installation.transport),
                {:ok, installed_options} <-
                  installed_options(installation, transport, credential_names) do
             {:ok,
              fn credentials ->
                acquire(
                  installation,
                  installed_options,
                  transport,
                  selected,
                  context,
                  credentials
                )
              end}
           end
         end
       }}
    end
  end

  defp prepare(_host, %{source: :llm} = installation, selection, context) do
    credential_names = [installation.credential]

    with :ok <- placement(installation, context.destination),
         {:ok, selected} <- llm_selection(installation, selection, context) do
      {:ok,
       %{
         credential_names: credential_names,
         data_class: installation.data_class,
         accepts_data: installation.accepts_data,
         preflight: fn ->
           with {:ok, model, adapter} <- preflight_llm(installation.model) do
             {:ok,
              fn credentials ->
                acquire_llm(
                  installation,
                  selected,
                  context,
                  model,
                  adapter,
                  credentials
                )
              end}
           end
         end
       }}
    end
  end

  defp placement(%{source: :mcp}, :mission), do: :ok
  defp placement(%{source: :mcp}, _destination), do: {:error, :provider_destination_denied}
  defp placement(%{source: :llm}, :workflow), do: :ok
  defp placement(%{source: :llm}, _destination), do: {:error, :provider_destination_denied}

  defp mcp_selection(installation, value, context)
       when is_map(value) and not is_struct(value) do
    public =
      Map.new(installation.tools, fn {_upstream, mapping} ->
        {mapping.as, mapping}
      end)

    with true <-
           Map.keys(value) -- ~w(allow model_visible timeout_ms max_result_bytes) == [],
         allow when is_list(allow) and length(allow) in 1..128 <-
           Map.get(value, "allow", public |> Map.keys() |> Enum.sort()),
         true <- Enum.all?(allow, &is_binary/1) and Enum.uniq(allow) == allow,
         true <- Enum.all?(allow, &Map.has_key?(public, &1)),
         installed_visible =
           Enum.filter(allow, fn name -> Map.fetch!(public, name).model_visible end),
         visible when is_list(visible) and length(visible) <= 128 <-
           Map.get(value, "model_visible", installed_visible),
         true <- Enum.all?(visible, &is_binary/1) and Enum.uniq(visible) == visible,
         true <- Enum.all?(visible, &(&1 in installed_visible)),
         timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 <-
           Map.get(
             value,
             "timeout_ms",
             min(installation.ceilings.timeout_ms, context.limits.evaluation_timeout_ms)
           ),
         true <- timeout_ms <= installation.ceilings.timeout_ms,
         true <- timeout_ms <= context.limits.evaluation_timeout_ms,
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
           Map.get(
             value,
             "max_result_bytes",
             min(
               installation.ceilings.max_result_bytes,
               context.limits.capability_result_bytes
             )
           ),
         true <- max_result_bytes <= installation.ceilings.max_result_bytes,
         true <- max_result_bytes <= context.limits.capability_result_bytes do
      {:ok,
       %{
         "allow" => allow,
         "model_visible" => visible,
         "timeout_ms" => timeout_ms,
         "max_result_bytes" => max_result_bytes
       }}
    else
      _reason -> {:error, :invalid_mcp_selection}
    end
  end

  defp mcp_selection(_installation, _value, _context), do: {:error, :invalid_mcp_selection}

  defp llm_selection(installation, value, context)
       when is_map(value) and not is_struct(value) do
    with true <- Map.keys(value) -- ~w(max_request_bytes max_response_bytes) == [],
         max_request_bytes when is_integer(max_request_bytes) and max_request_bytes > 0 <-
           Map.get(
             value,
             "max_request_bytes",
             min(
               installation.ceilings.max_request_bytes,
               context.limits.capability_argument_bytes
             )
           ),
         true <- max_request_bytes <= installation.ceilings.max_request_bytes,
         true <- max_request_bytes <= context.limits.capability_argument_bytes,
         max_response_bytes when is_integer(max_response_bytes) and max_response_bytes > 0 <-
           Map.get(
             value,
             "max_response_bytes",
             min(
               installation.ceilings.max_response_bytes,
               context.limits.capability_result_bytes
             )
           ),
         true <- max_response_bytes <= installation.ceilings.max_response_bytes,
         true <- max_response_bytes <= context.limits.capability_result_bytes do
      {:ok,
       %{
         max_request_bytes: max_request_bytes,
         max_response_bytes: max_response_bytes
       }}
    else
      _reason -> {:error, :invalid_llm_selection}
    end
  end

  defp llm_selection(_installation, _value, _context), do: {:error, :invalid_llm_selection}

  defp credential_names(%{type: :stdio, env: env}),
    do: env |> Map.values() |> Enum.uniq() |> Enum.sort()

  defp credential_names(%{type: :streamable_http, auth: auth}),
    do: auth |> Enum.map(& &1.binding) |> Enum.uniq() |> Enum.sort()

  defp preflight_transport(_host, %{type: :streamable_http} = transport),
    do: {:ok, transport}

  defp preflight_transport(host, %{type: :stdio} = transport) do
    with {:ok, environment} <- compatibility_environment(transport.inherit_environment),
         {:ok, cwd} <- canonical_directory(host.directory, transport.cwd),
         {:ok, executable, executable_sha256} <-
           resolve_command(transport.command, environment),
         {:ok, launcher, launcher_sha256} <- resolve_launcher(host.runtime.stdio_launcher) do
      {:ok,
       Map.merge(transport, %{
         cwd: cwd,
         executable: executable,
         executable_sha256: executable_sha256,
         launcher: launcher,
         launcher_sha256: launcher_sha256,
         compatibility_environment: environment
       })}
    end
  end

  defp installed_options(installation, transport, _credential_names) do
    options = [
      tools: installation.tools,
      timeout_ms: installation.ceilings.timeout_ms,
      max_result_bytes: installation.ceilings.max_result_bytes,
      max_catalog_tools: installation.ceilings.max_catalog_tools,
      installation_revision: installation.installation_revision
    ]

    case transport.type do
      :streamable_http ->
        try do
          _builder =
            MCPSource.builder([
              {:transport,
               {:streamable_http, endpoint: transport.endpoint, headers: fn -> [] end}}
              | options
            ])

          {:ok, options}
        rescue
          ArgumentError -> {:error, :invalid_mcp_transport}
        end

      :stdio ->
        transport_options =
          [
            launcher: transport.launcher,
            executable: transport.executable,
            executable_sha256: transport.executable_sha256,
            cwd: transport.cwd,
            args: transport.args,
            env: transport.compatibility_environment,
            grace_ms: transport.grace_ms,
            stderr_bytes: transport.stderr_bytes,
            start_timeout_ms: transport.start_timeout_ms
          ]

        try do
          _builder = MCPSource.builder([transport: {:stdio, transport_options}] ++ options)
          {:ok, options}
        rescue
          ArgumentError -> {:error, :invalid_mcp_transport}
        end
    end
  end

  defp acquire(
         installation,
         options,
         %{type: :streamable_http} = transport,
         selected,
         context,
         credentials
       ) do
    with {:ok, headers} <- render_headers(transport.auth, credentials) do
      options =
        [
          transport: {:streamable_http, endpoint: transport.endpoint, headers: fn -> headers end}
        ] ++ options

      options
      |> MCPSource.builder()
      |> then(& &1.(selected, context))
      |> classify(installation)
    end
  end

  defp acquire(installation, options, %{type: :stdio} = transport, selected, context, credentials) do
    with {:ok, credential_environment} <- render_environment(transport.env, credentials) do
      environment = Map.merge(transport.compatibility_environment, credential_environment)

      transport_options = [
        launcher: transport.launcher,
        executable: transport.executable,
        executable_sha256: transport.executable_sha256,
        cwd: transport.cwd,
        args: transport.args,
        env: environment,
        grace_ms: transport.grace_ms,
        stderr_bytes: transport.stderr_bytes,
        start_timeout_ms: transport.start_timeout_ms
      ]

      ([transport: {:stdio, transport_options}] ++ options)
      |> MCPSource.builder()
      |> then(& &1.(selected, context))
      |> classify(installation)
    end
  end

  defp preflight_llm(model) do
    with {:ok, resolved} <- PtcRunner.LLM.Registry.resolve(model),
         true <- is_binary(resolved) and byte_size(resolved) in 1..256,
         adapter when is_atom(adapter) <- PtcRunner.LLM.adapter!(),
         true <- Code.ensure_loaded?(adapter) do
      {:ok, resolved, adapter}
    else
      _invalid -> {:error, :invalid_llm_model}
    end
  rescue
    _exception -> {:error, :invalid_llm_model}
  end

  defp acquire_llm(installation, selected, context, model, adapter, credentials) do
    with {:ok, credential} <- Map.fetch(credentials, installation.credential),
         requester =
           PtcRunner.LLM.callback(
             model,
             adapter: adapter,
             cache: installation.cache,
             api_key: credential
           ),
         {:ok, capability} <-
           LLMCapability.new(
             requester: fn request ->
               requester.(ProviderRegistry.adapter_request(request))
             end,
             max_request_bytes: selected.max_request_bytes,
             max_response_bytes: selected.max_response_bytes
           ),
         {:ok, snapshot} <- llm_snapshot(installation, selected, context.provider, model) do
      {:ok,
       %{
         capabilities: [capability],
         snapshot: snapshot,
         close: nil,
         data_class: installation.data_class,
         accepts_data: installation.accepts_data
       }}
    else
      _reason -> {:error, :invalid_llm_provider}
    end
  rescue
    _exception -> {:error, :invalid_llm_provider}
  end

  defp llm_snapshot(installation, selected, provider, model) do
    identity =
      %{
        "source" => "llm",
        "model" => model,
        "cache" => installation.cache,
        "max_request_bytes" => selected.max_request_bytes,
        "max_response_bytes" => selected.max_response_bytes
      }
      |> maybe_put("installation_revision", installation.installation_revision)

    with {:ok, encoded} <- DeterministicJSON.encode(identity) do
      {:ok,
       identity
       |> Map.put("provider", provider)
       |> Map.put("snapshot_hash", sha256(encoded))}
    end
  end

  defp classify({:ok, built}, installation) do
    {:ok,
     built
     |> Map.put(:data_class, installation.data_class)
     |> Map.put(:accepts_data, installation.accepts_data)}
  end

  defp classify({:error, _reason} = error, _installation), do: error

  defp compatibility_environment(false), do: {:ok, %{}}

  defp compatibility_environment(true) do
    Enum.reduce_while(@compatibility_environment, {:ok, %{}}, fn name, {:ok, environment} ->
      case System.get_env(name) do
        nil ->
          {:cont, {:ok, environment}}

        value ->
          if shell_function?(value) or not valid_secret?(value) do
            {:halt, {:error, :invalid_compatibility_environment}}
          else
            {:cont, {:ok, Map.put(environment, name, value)}}
          end
      end
    end)
  end

  defp shell_function?(value),
    do: String.starts_with?(String.trim_leading(value), "() {")

  defp canonical_directory(base, path) do
    candidate = if Path.type(path) == :absolute, do: path, else: Path.expand(path, base)

    with {:ok, canonical} <- ConfinedFile.resolve_absolute(candidate),
         {:ok, %{type: :directory}} <- File.stat(canonical) do
      {:ok, canonical}
    else
      _reason -> {:error, :invalid_mcp_working_directory}
    end
  end

  defp resolve_command(command, environment) do
    case Path.type(command) do
      :absolute ->
        canonical_executable(command, @max_executable_bytes, :invalid_mcp_executable)

      :relative ->
        if Path.basename(command) == command do
          resolve_bare_command(command, Map.get(environment, "PATH"))
        else
          {:error, :invalid_mcp_executable}
        end
    end
  end

  defp resolve_bare_command(_command, nil), do: {:error, :invalid_mcp_executable}

  defp resolve_bare_command(command, path) do
    path
    |> String.split(":", trim: true)
    |> Enum.reduce_while({:error, :invalid_mcp_executable}, fn directory, _error ->
      if Path.type(directory) == :absolute do
        case canonical_executable(
               Path.join(directory, command),
               @max_executable_bytes,
               :invalid_mcp_executable
             ) do
          {:ok, _path, _digest} = success -> {:halt, success}
          {:error, _reason} -> {:cont, {:error, :invalid_mcp_executable}}
        end
      else
        {:cont, {:error, :invalid_mcp_executable}}
      end
    end)
  end

  defp resolve_launcher(nil) do
    launcher_module = Module.concat(["PtcRunnerLauncher"])

    if Code.ensure_loaded?(launcher_module) and
         function_exported?(launcher_module, :protocol_version, 0) and
         function_exported?(launcher_module, :executable_path, 0) and
         launcher_module.protocol_version() == @launcher_protocol_version do
      case launcher_module.executable_path() do
        {:ok, path} ->
          case canonical_executable(path, @max_launcher_bytes, :mcp_stdio_launcher_unavailable) do
            {:ok, canonical, digest} -> {:ok, canonical, digest}
            {:error, _reason} = error -> error
          end

        {:error, :unsupported_platform} ->
          {:error, :unsupported_mcp_stdio_platform}

        {:error, _reason} ->
          {:error, :mcp_stdio_launcher_unavailable}
      end
    else
      {:error, :mcp_stdio_launcher_unavailable}
    end
  end

  defp resolve_launcher(path) do
    case canonical_executable(path, @max_launcher_bytes, :mcp_stdio_launcher_unavailable) do
      {:ok, canonical, digest} -> {:ok, canonical, digest}
      {:error, _reason} = error -> error
    end
  end

  defp canonical_executable(path, max_bytes, error) do
    with {:ok, canonical} <- ConfinedFile.resolve_absolute(path),
         {:ok, stat} <- File.stat(canonical),
         true <- stat.type == :regular and stat.size in 1..max_bytes,
         true <- Bitwise.band(stat.mode, 0o111) != 0,
         {:ok, digest} <- hash_file(canonical, max_bytes) do
      {:ok, canonical, digest}
    else
      _reason -> {:error, error}
    end
  end

  defp hash_file(path, max_bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          hash_chunks(device, :crypto.hash_init(:sha256), 0, max_bytes)
        after
          File.close(device)
        end

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp hash_chunks(device, hash, bytes, max_bytes) do
    case IO.binread(device, 65_536) do
      :eof ->
        {:ok, :crypto.hash_final(hash)}

      chunk when is_binary(chunk) and bytes + byte_size(chunk) <= max_bytes ->
        hash_chunks(
          device,
          :crypto.hash_update(hash, chunk),
          bytes + byte_size(chunk),
          max_bytes
        )

      _error_or_exceeded ->
        {:error, :unreadable}
    end
  end

  defp resolve_credentials(host, names) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, resolved} ->
      with {:ok, declaration} <- Map.fetch(host.credentials, name),
           {:ok, value} <- resolve_credential(host.directory, declaration),
           true <- valid_secret?(value) do
        {:cont, {:ok, Map.put(resolved, name, value)}}
      else
        _reason -> {:halt, {:error, :credential_unavailable}}
      end
    end)
  end

  defp resolve_credential(_directory, %{source: :env, name: name}),
    do: System.fetch_env(name)

  defp resolve_credential(directory, %{source: :file, path: path}) do
    if Path.type(path) == :absolute do
      with {:ok, canonical} <- ConfinedFile.resolve_absolute(path),
           do:
             ConfinedFile.read(
               Path.dirname(canonical),
               Path.basename(canonical),
               @max_credential_bytes
             )
    else
      ConfinedFile.read(directory, path, @max_credential_bytes)
    end
  end

  defp resolve_credential(_directory, %{source: :literal, value: value}),
    do: {:ok, value}

  defp valid_secret?(value),
    do:
      is_binary(value) and byte_size(value) in 1..@max_credential_bytes and
        String.valid?(value) and not String.contains?(value, <<0>>)

  defp render_environment(bindings, credentials) do
    Enum.reduce_while(bindings, {:ok, %{}}, fn {name, binding}, {:ok, environment} ->
      case Map.fetch(credentials, binding) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(environment, name, value)}}

        :error ->
          {:halt, {:error, :credential_unavailable}}
      end
    end)
  end

  defp render_headers(auth, credentials) do
    Enum.reduce_while(auth, {:ok, []}, fn entry, {:ok, headers} ->
      with {:ok, secret} <- Map.fetch(credentials, entry.binding),
           false <- String.contains?(secret, ["\r", "\n"]) do
        header =
          case entry.scheme do
            :bearer -> {"Authorization", "Bearer " <> secret}
            :basic -> {"Authorization", "Basic " <> secret}
            :api_key -> {entry.header, secret}
          end

        {:cont, {:ok, [header | headers]}}
      else
        _reason -> {:halt, {:error, :credential_unavailable}}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp sha256(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
