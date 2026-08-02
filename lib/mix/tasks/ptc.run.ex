defmodule Mix.Tasks.Ptc.Run do
  @shortdoc "Runs one strict PTC Kernel manifest"
  @moduledoc """
  Runs one V1 Kernel manifest through the shared run builder.

      mix ptc.run MANIFEST
      mix ptc.run MANIFEST --mission alternate-input.json
      mix ptc.run MANIFEST --private-mission private-input.json --private-output result.json
      mix ptc.run MANIFEST --trace traces/run.jsonl
      mix ptc.run MANIFEST --trace traces/run.jsonl --inspect traces/run.inspection.jsonl
      mix ptc.run MANIFEST --output results/answer.json
      mix ptc.run MANIFEST --private-output results/answer.private.json
      mix ptc.run MANIFEST --host-config ptc-host.json
      mix ptc.run MANIFEST --host-config ptc-host.json --authorize-mcp NAME
      mix ptc.run MANIFEST --host-config ptc-host.json --check
      mix ptc.run MANIFEST --component-override-descriptor private/agent.core.override.json

  `--output` and `--private-output` write the result value as a standalone
  JSON artifact so a later run can consume it without scraping stdout. Both
  refuse to overwrite an existing destination and are mutually exclusive.
  Deterministic destination and data-class conflicts fail before provider
  acquisition; exclusive publication still protects against later races.
  `--private-mission` is mutually exclusive with `--mission`, loads the same
  manifest-confined JSON shape, and classifies the entire run before provider
  activity.

  A private-event run may not publish. It suppresses its value on stdout,
  rejects `--output`, and requires `--private-output` to keep the value at all.

  `--component-override-descriptor` is host authority for candidate
  evaluation. It names one already-selected component, the hash of the base it
  was derived from, and the hash of replacement source confined to the
  descriptor's own directory. Both hashes are verified before the source
  reaches the compiler, and the verified identity is recorded in run-started
  metadata so a trial artifact names the base as well as the candidate. A
  manifest cannot request one and a generated program cannot observe one.

  `--host-config` installs the exact provider aliases declared by one strict,
  bounded host document. `--check` assembles and discovers those providers,
  prints a safe resolved view including MCP read/write tool counts, and closes
  every resource without invoking the workflow or a model. A provider-bearing
  manifest requires `--host-config`; provider-free manifests continue to run
  without one.
  """
  use Mix.Task

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Authorization
  alias PtcRunner.Kernel.MCPOAuth.Context, as: OAuthContext
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Lisp.Format.SymbolRef

  @usage "usage: mix ptc.run MANIFEST [--mission PATH | --private-mission PATH] " <>
           "[--trace PATH] [--inspect PATH] " <>
           "[--output PATH | --private-output PATH] [--host-config PATH] " <>
           "[--authorize-mcp NAME] [--component-override-descriptor PATH] [--check]"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    with {opts, [manifest], []} <-
           OptionParser.parse(args,
             strict: [
               mission: :string,
               private_mission: :string,
               trace: :string,
               inspect: :string,
               output: :string,
               private_output: :string,
               host_config: :string,
               authorize_mcp: :keep,
               component_override_descriptor: :string,
               check: :boolean
             ],
             aliases: [m: :mission, t: :trace]
           ),
         :ok <- exclusive_destinations(opts),
         :ok <- exclusive_mission_inputs(opts),
         :ok <- check_options(opts),
         {:ok, registry, host} <- registry(opts) do
      try do
        run_opts = run_options(opts)

        result =
          if Keyword.get(opts, :check, false) do
            with {:ok, view} <- check(manifest, registry, host, run_opts) do
              report_check(view)
            end
          else
            with {:ok, result, class} <- run_with_class(manifest, registry, run_opts) do
              report(result, class, opts)
            end
          end

        case result do
          {:error, error} ->
            Mix.raise("ptc.run failed: #{inspect(error, limit: 10, printable_limit: 1_024)}")

          completed ->
            completed
        end
      after
        ProviderRegistry.close(registry)
      end
    else
      {_opts, _arguments, invalid} when invalid != [] ->
        Mix.raise("invalid ptc.run options: #{inspect(invalid)}")

      {_opts, _arguments, _invalid} ->
        Mix.raise(@usage)

      {:error, error} ->
        Mix.raise("ptc.run failed: #{inspect(error, limit: 10, printable_limit: 1_024)}")
    end
  end

  defp exclusive_destinations(opts) do
    if Keyword.has_key?(opts, :output) and Keyword.has_key?(opts, :private_output) do
      {:error, :conflicting_result_destinations}
    else
      :ok
    end
  end

  defp exclusive_mission_inputs(opts) do
    if Keyword.has_key?(opts, :mission) and Keyword.has_key?(opts, :private_mission) do
      {:error, :conflicting_mission_inputs}
    else
      :ok
    end
  end

  defp check_options(opts) do
    if Keyword.get(opts, :check, false) and
         Enum.any?([:output, :private_output, :trace, :inspect], &Keyword.has_key?(opts, &1)) do
      {:error, :check_has_output_options}
    else
      :ok
    end
  end

  defp registry(opts) do
    authorizations = Keyword.get_values(opts, :authorize_mcp)

    case {Keyword.get(opts, :host_config), authorizations} do
      {nil, []} ->
        with {:ok, catalog} <- InstallationCatalog.new(),
             {:ok, services} <- ProviderRuntimeServices.new(),
             {:ok, registry} <- InstallationCatalog.runtime_registry(catalog, services),
             do: {:ok, registry, nil}

      {nil, _requested} ->
        {:error, :authorization_requires_host_config}

      {path, requested} ->
        with true <- requested == Enum.uniq(requested),
             {:ok, host} <- HostConfig.load(path),
             {:ok, memory} <- Memory.start_link(owner: self()),
             {:ok, store} <- Memory.store(memory),
             {:ok, authorization_context} <-
               OAuthContext.new(
                 tenant_id: "local-cli",
                 principal_id: "local-user",
                 store: store
               ),
             :ok <- authorize_installations(host, authorization_context, requested),
             {:ok, catalog} <- HostInstallation.catalog(host),
             {:ok, services} <-
               HostInstallation.runtime_services(host,
                 oauth_mode: {:context_factory, fn -> {:ok, authorization_context} end}
               ) do
          try do
            with {:ok, registry} <-
                   InstallationCatalog.runtime_registry(catalog, services) do
              {:ok, registry, host}
            end
          after
            InstallationCatalog.close(catalog)
          end
        else
          false -> {:error, :duplicate_mcp_authorization}
          {:error, _reason} = error -> error
          _invalid -> {:error, :invalid_mcp_authorization}
        end
    end
  end

  defp authorize_installations(host, context, requested) do
    Enum.reduce_while(requested, :ok, fn name, :ok ->
      case Map.get(host.install, name) do
        %{source: :mcp, transport: %{oauth: authority}} when not is_nil(authority) ->
          case authorize_installation(context, authority) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        _missing_or_not_oauth ->
          {:halt, {:error, :invalid_mcp_authorization}}
      end
    end)
  end

  defp authorize_installation(context, authority) do
    with true <- Authority.cli_compatible?(authority),
         {:ok, listener} <- LoopbackListener.start(authority) do
      authorize_with_listener(context, authority, listener)
    else
      false -> {:error, :mcp_authorization_not_cli_compatible}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_with_listener(context, authority, listener) do
    case Authorization.begin_authorization(context, authority,
           redirect_uri: listener.redirect_uri
         ) do
      {:ok, pending} ->
        Mix.shell().info("Open this one-time authorization URL:\n#{pending.url}")

        case LoopbackListener.await(listener, context, pending, []) do
          {:ok, _grant} -> :ok
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        LoopbackListener.close(listener)
        error
    end
  end

  defp run_options(opts) do
    opts
    |> Keyword.drop([:host_config, :authorize_mcp, :check])
    |> Keyword.put(:result_projection, :json)
  end

  defp check(manifest, registry, host, opts) do
    with {:ok, built} <- RunBuilder.load_and_build(manifest, registry, opts) do
      view = resolved_view(built, host)

      case RunBuilder.close(built.config) do
        :ok -> {:ok, view}
        {:error, _reason} = error -> error
      end
    end
  end

  defp resolved_view(built, host) do
    built.config.connector_snapshots
    |> Enum.map(fn snapshot ->
      installation = if host, do: host.install[snapshot["provider"]]
      resolved_provider(snapshot, installation)
    end)
    |> Enum.sort_by(&{&1["environment"], &1["name"]})
  end

  defp resolved_provider(snapshot, %{source: :mcp} = installation) do
    acquisition = snapshot["acquisition"]
    effects = Enum.frequencies_by(acquisition["tools"], & &1["effect"])

    %{
      "environment" => "mission",
      "name" => snapshot["provider"],
      "summary" =>
        "mcp/#{acquisition["transport"]}  #{length(acquisition["tools"])} tools  " <>
          "#{Map.get(effects, "read", 0)} read  #{Map.get(effects, "write", 0)} write  " <>
          "auth #{authorization_mode(installation.transport)}",
      "accepts_data" => Enum.map(installation.accepts_data, &Atom.to_string/1),
      "snapshot_hash" => snapshot["snapshot_hash"]
    }
  end

  defp resolved_provider(snapshot, %{source: :llm} = installation) do
    %{
      "environment" => "workflow",
      "name" => snapshot["provider"],
      "summary" => "llm  revision #{snapshot["declaration"]["installation_revision"]}",
      "accepts_data" => Enum.map(installation.accepts_data, &Atom.to_string/1),
      "snapshot_hash" => snapshot["snapshot_hash"]
    }
  end

  defp resolved_provider(snapshot, %{source: :llm_replay} = installation) do
    acquisition = snapshot["acquisition"]

    %{
      "environment" => "workflow",
      "name" => snapshot["provider"],
      "summary" =>
        "llm_replay  #{acquisition["entry_count"]} entries  " <>
          "#{acquisition["response_count"]} responses",
      "accepts_data" => Enum.map(installation.accepts_data, &Atom.to_string/1),
      "snapshot_hash" => snapshot["snapshot_hash"]
    }
  end

  defp resolved_provider(snapshot, %{source: :ptc_trace_snapshot}) do
    %{
      "environment" => "mission",
      "name" => snapshot["provider"],
      "summary" => "ptc_trace_snapshot  4 operations",
      "accepts_data" => ["normal", "private_inspection"],
      "snapshot_hash" => snapshot["snapshot_hash"]
    }
  end

  defp resolved_provider(snapshot, %{source: :ptc_inspection_snapshot}) do
    %{
      "environment" => "mission",
      "name" => snapshot["provider"],
      "summary" => "ptc_inspection_snapshot  6 operations  data private_inspection",
      "accepts_data" => ["normal", "private_inspection"],
      "snapshot_hash" => snapshot["snapshot_hash"]
    }
  end

  defp resolved_provider(snapshot, _installation) do
    %{
      "environment" => "mission",
      "name" => snapshot["provider"],
      "summary" => "provider  1 capabilities",
      "accepts_data" => ["normal"],
      "snapshot_hash" => snapshot["snapshot_hash"]
    }
  end

  defp report_check([]), do: Mix.shell().info("check ok: no providers")

  defp report_check(view) do
    Enum.each(view, fn provider ->
      Mix.shell().info(
        "#{provider["environment"]}  #{provider["name"]}  " <>
          "#{provider["summary"]}  " <>
          "accepts: #{Enum.join(provider["accepts_data"], ", ")}  " <>
          "snapshot #{provider["snapshot_hash"]}"
      )
    end)
  end

  defp authorization_mode(%{oauth: oauth}) when not is_nil(oauth), do: "oauth"
  defp authorization_mode(%{auth: auth}) when auth in [nil, []], do: "none"
  defp authorization_mode(_transport), do: "static"

  defp run_with_class(manifest, registry, opts),
    do: RunBuilder.run_with_class(manifest, registry, opts)

  # A private value never reaches the terminal. Publishing it there would
  # declassify it just as surely as writing it to a normal artifact.
  defp report(result, :private, opts) do
    unless Keyword.has_key?(opts, :private_output) do
      Mix.raise(
        "ptc.run failed: a private run requires --private-output; its value is not published"
      )
    end

    Mix.shell().info(Jason.encode!(%{"class" => "private", "usage" => public(result.usage)}))
  end

  defp report(result, :normal, _opts),
    do: Mix.shell().info(Jason.encode!(public(result)))

  defp public(%SymbolRef{} = value), do: Kernel.to_string(value)
  defp public(struct) when is_struct(struct), do: struct |> Map.from_struct() |> public()

  defp public(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {public_key(key), public(value)} end)

  defp public(list) when is_list(list), do: Enum.map(list, &public/1)
  defp public(value), do: value

  defp public_key(%SymbolRef{} = key), do: Kernel.to_string(key)
  defp public_key(key), do: key
end
