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

  alias PtcRunner.Dotenv
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Authorization
  alias PtcRunner.Kernel.MCPOAuth.Context, as: OAuthContext
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActiveSession
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Lisp.Format.SymbolRef

  @usage "usage: mix ptc.run MANIFEST [--mission PATH | --private-mission PATH] " <>
           "[--trace PATH] [--inspect PATH] " <>
           "[--output PATH | --private-output PATH] [--host-config PATH] " <>
           "[--authorize-mcp NAME] [--component-override-descriptor PATH] [--check]"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    start_core_application!()

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
         {:ok, runtime} <- runtime(opts) do
      try do
        result = execute(manifest, opts, runtime)

        case result do
          {:error, error} ->
            raise_failure(error)

          completed ->
            completed
        end
      after
        InstallationCatalog.close(runtime.catalog)
      end
    else
      {_opts, _arguments, invalid} when invalid != [] ->
        Mix.raise("invalid ptc.run options: #{inspect(invalid)}")

      {_opts, _arguments, _invalid} ->
        Mix.raise(@usage)

      {:error, error} ->
        raise_failure(error)
    end
  end

  defp start_core_application! do
    case Application.ensure_all_started(:ptc_runner) do
      {:ok, _started} -> :ok
      {:error, reason} -> Mix.raise("could not start PtcRunner: #{inspect(reason)}")
    end
  end

  defp execute(manifest, opts, runtime) do
    with {:ok, request} <- request(manifest, runtime.catalog, opts),
         {:ok, prepared} <- RunCoordinator.prepare(request, runtime.catalog) do
      try do
        with :ok <- validate_authorization_targets(prepared, runtime),
             {:ok, run_opts} <- RunBuilder.preflight_prepared(prepared, run_options(opts)) do
          execute_prepared(prepared, run_opts, opts, runtime)
        end
      after
        PreparedRun.close(prepared)
      end
    end
  end

  defp execute_prepared(
         prepared,
         run_opts,
         opts,
         runtime
       ) do
    with :ok <- load_environment_credentials(prepared, runtime) do
      if Keyword.get(opts, :check, false) do
        execute_check_prepared(prepared, run_opts, opts, runtime)
      else
        execute_one_shot(prepared, run_opts, opts, runtime)
      end
    end
  end

  defp execute_check_prepared(
         %PreparedRun{provider_declarations: []} = prepared,
         run_opts,
         opts,
         runtime
       ) do
    with {:ok, registry} <-
           ProviderRegistry.new(%{}, installed_limits: runtime.catalog.installed_limits) do
      try do
        execute_with_registry(prepared, registry, nil, run_opts, opts, runtime.host)
      after
        ProviderRegistry.close(registry)
      end
    end
  end

  defp execute_check_prepared(
         prepared,
         run_opts,
         opts,
         %{authorizations: [_first | _rest]} = runtime
       ) do
    case ProviderActiveSession.open_setup(prepared, runtime.catalog, runtime.services) do
      {:ok, setup_session} ->
        execute_after_authorization_setup(
          prepared,
          setup_session,
          run_opts,
          opts,
          runtime
        )

      {:error, %CommandDiagnostic{}} = error ->
        error
    end
  end

  defp execute_check_prepared(prepared, run_opts, opts, runtime) do
    case ProviderActiveSession.open(prepared, runtime.catalog, runtime.services) do
      {:ok, session} ->
        case active_registry(prepared, session, runtime) do
          {:ok, registry, cleanup} ->
            try do
              execute_with_registry(prepared, registry, session, run_opts, opts, runtime.host)
            after
              cleanup.()
            end

          {:error, _reason} = error ->
            _ = ProviderSession.close(session)
            error
        end

      {:error, %CommandDiagnostic{}} = error ->
        error
    end
  end

  defp execute_one_shot(prepared, run_opts, opts, runtime) do
    with {:ok, authority} <- PublicationAuthority.new(run_opts),
         {:ok, outcome} <- execute_owned(prepared, authority, runtime),
         {:ok, value, class} <- RunBuilder.publish_execution(outcome, authority) do
      report(value, class, opts)
    end
  end

  defp execute_owned(%PreparedRun{provider_declarations: []} = prepared, authority, _runtime),
    do: RunCoordinator.execute(prepared, authority)

  defp execute_owned(prepared, authority, runtime) do
    RunCoordinator.execute(prepared, authority, runtime.execution, fn url ->
      Mix.shell().info("Open this one-time authorization URL:\n#{url}")
      :ok
    end)
  end

  defp execute_after_authorization_setup(prepared, setup_session, run_opts, opts, runtime) do
    selected_names = selected_provider_names(prepared)
    authorities = oauth_authorities(runtime.host, selected_names)

    result =
      with deadline when not is_nil(deadline) <-
             oauth_setup_deadline(
               prepared.provider_declarations,
               authorities,
               selected_names,
               System.monotonic_time(:millisecond)
             ),
           {:ok, registry, context, cleanup} <-
             open_oauth_registry(runtime, selected_names, deadline) do
        try do
          with :ok <-
                 authorize_installations(
                   runtime.host,
                   context,
                   registry,
                   prepared.provider_declarations,
                   authorities,
                   runtime.authorizations
                 )
                 |> authorization_result(selected_names, runtime.catalog),
               {:ok, session} <-
                 ProviderActiveSession.begin_run(setup_session, prepared, runtime.catalog) do
            execute_with_registry(prepared, registry, session, run_opts, opts, runtime.host)
          end
        after
          cleanup.()
        end
      else
        nil -> {:error, :invalid_mcp_authorization}
        {:error, _reason} = error -> error
      end

    close_unstarted_session(setup_session, result)
  end

  defp execute_with_registry(prepared, registry, session, run_opts, opts, host) do
    with true <- Keyword.get(opts, :check, false),
         {:ok, view} <- check(prepared, registry, session, host, run_opts) do
      report_check(view)
    else
      false -> {:error, :invalid_check}
      {:error, _reason} = error -> error
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

  defp runtime(opts) do
    authorizations = Keyword.get_values(opts, :authorize_mcp)
    provider_application_mode = provider_application_mode()

    case {Keyword.get(opts, :host_config), authorizations} do
      {nil, []} ->
        with {:ok, nil, catalog} <- CommandEngine.catalog(nil),
             {:ok, services} <-
               ProviderRuntimeServices.new(provider_application_mode: provider_application_mode),
             {:ok, execution} <- ProviderExecution.new(catalog, services, []) do
          {:ok,
           %{
             catalog: catalog,
             services: services,
             host: nil,
             authorizations: [],
             execution: execution
           }}
        end

      {nil, _requested} ->
        {:error, :authorization_requires_host_config}

      {path, requested} ->
        with true <- requested == Enum.uniq(requested),
             {:ok, host, catalog} <- CommandEngine.catalog(path),
             {:ok, services} <-
               HostInstallation.runtime_services(host,
                 provider_application_mode: provider_application_mode
               ),
             {:ok, execution} <- ProviderExecution.new(catalog, services, requested) do
          {:ok,
           %{
             catalog: catalog,
             services: services,
             host: host,
             authorizations: requested,
             execution: execution
           }}
        else
          false -> {:error, :duplicate_mcp_authorization}
          {:error, _reason} = error -> error
        end
    end
  end

  defp active_registry(
         prepared,
         session,
         %{host: nil, catalog: catalog, services: services}
       ) do
    catalog
    |> InstallationCatalog.runtime_registry(
      services,
      selected_provider_names(prepared),
      ProviderSession.run_deadline(session)
    )
    |> registry_result(:run)
  end

  defp active_registry(prepared, session, runtime) do
    selected_names = selected_provider_names(prepared)
    authorities = oauth_authorities(runtime.host, selected_names)

    if Enum.any?(authorities, fn {_name, authority} -> not is_nil(authority) end) do
      run_deadline = ProviderSession.run_deadline(session)

      oauth_deadline =
        oauth_operation_deadline(
          run_deadline,
          prepared.provider_declarations,
          authorities,
          System.monotonic_time(:millisecond)
        )

      with {:ok, registry, _context, cleanup} <-
             open_oauth_registry(runtime, selected_names, oauth_deadline) do
        {:ok, registry, cleanup}
      end
    else
      runtime.catalog
      |> InstallationCatalog.runtime_registry(
        runtime.services,
        selected_names,
        ProviderSession.run_deadline(session)
      )
      |> registry_result(:run)
    end
  end

  defp open_oauth_registry(runtime, selected_names, deadline) do
    with {:ok, memory} <- Memory.start_link(owner: self()) do
      result =
        with {:ok, store} <- Memory.store(memory),
             {:ok, context} <-
               OAuthContext.new(
                 tenant_id: "local-cli",
                 principal_id: "local-user",
                 store: store,
                 deadline: deadline
               ),
             {:ok, services} <-
               HostInstallation.runtime_services(runtime.host,
                 provider_application_mode: runtime.services.provider_application_mode,
                 oauth_mode:
                   {:context_factory,
                    fn
                      ^deadline -> {:ok, context}
                      _other -> {:error, :authorization_context_required}
                    end}
               ),
             {:ok, registry} <-
               InstallationCatalog.runtime_registry(
                 runtime.catalog,
                 services,
                 selected_names,
                 deadline
               )
               |> registry_result({:oauth, selected_names, runtime.catalog}) do
          {:ok, registry, context,
           fn ->
             ProviderRegistry.close(registry)
             Memory.close(memory)
           end}
        end

      case result do
        {:ok, _registry, _context, _cleanup} = success ->
          success

        {:error, _reason} = error ->
          error
          |> registry_result({:oauth, selected_names, runtime.catalog})
          |> then(&close_memory(memory, &1))
      end
    end
  end

  defp selected_provider_names(prepared),
    do: prepared.provider_declarations |> Enum.map(& &1.name) |> Enum.uniq()

  @doc false
  @spec oauth_authorities(map(), [binary()]) :: %{binary() => Authority.t() | nil}
  def oauth_authorities(%{install: install}, selected_names)
      when is_map(install) and is_list(selected_names) do
    Map.new(selected_names, fn name ->
      authority =
        case Map.get(install, name) do
          %{source: :mcp, transport: %{oauth: %Authority{} = authority}} -> authority
          _not_oauth -> nil
        end

      {name, authority}
    end)
  end

  def oauth_authorities(_host, _selected_names), do: %{}

  @doc false
  @spec authorization_result(:ok | {:error, term()}, [binary()], InstallationCatalog.t()) ::
          :ok | {:error, term()}
  def authorization_result(:ok, _selected_names, _catalog), do: :ok

  def authorization_result({:error, _reason} = result, selected_names, catalog),
    do: registry_result(result, {:oauth, selected_names, catalog})

  @doc false
  @spec oauth_operation_deadline(Deadline.t(), [map()], map(), integer()) :: Deadline.t()
  def oauth_operation_deadline(run_deadline, declarations, authorities, anchor_ms) do
    Enum.reduce(declarations, run_deadline, fn declaration, deadline ->
      case declaration do
        %{name: name, config: %{"timeout_ms" => timeout_ms}}
        when is_integer(timeout_ms) and timeout_ms > 0 ->
          if Map.get(authorities, name) do
            Deadline.earliest(deadline, Deadline.new(timeout_ms, anchor_ms))
          else
            deadline
          end

        _declaration ->
          deadline
      end
    end)
  end

  @doc false
  @spec oauth_setup_deadline([map()], map(), [binary()], integer()) :: Deadline.t() | nil
  def oauth_setup_deadline(declarations, authorities, selected_names, anchor_ms) do
    Enum.reduce(selected_names, nil, fn name, deadline ->
      case oauth_target_deadline(name, declarations, authorities, anchor_ms) do
        nil -> deadline
        target when is_nil(deadline) -> target
        target -> Deadline.earliest(deadline, target)
      end
    end)
  end

  @doc false
  @spec oauth_target_deadline(binary(), [map()], map(), integer()) :: Deadline.t() | nil
  def oauth_target_deadline(name, declarations, authorities, anchor_ms) do
    case Map.get(authorities, name) do
      %{authorization_timeout_ms: timeout_ms}
      when is_integer(timeout_ms) and timeout_ms > 0 ->
        Enum.reduce(declarations, Deadline.new(timeout_ms, anchor_ms), fn declaration, deadline ->
          case declaration do
            %{name: ^name, config: %{"timeout_ms" => occurrence_timeout_ms}}
            when is_integer(occurrence_timeout_ms) and occurrence_timeout_ms > 0 ->
              Deadline.earliest(deadline, Deadline.new(occurrence_timeout_ms, anchor_ms))

            _other ->
              deadline
          end
        end)

      _not_oauth ->
        nil
    end
  end

  defp registry_result({:ok, registry}, :run),
    do: {:ok, registry, fn -> ProviderRegistry.close(registry) end}

  defp registry_result({:ok, registry}, {:oauth, _selected_names, _catalog}),
    do: {:ok, registry}

  defp registry_result({:error, :operation_deadline_expired}, :run),
    do: {:error, CommandDiagnostic.new!(:execution, :run_timeout, provider_activity: true)}

  defp registry_result(
         {:error, {:authorization_timeout, name}},
         {:oauth, _selected_names, _catalog}
       ),
       do: {:error, authorization_diagnostic(name)}

  defp registry_result(
         {:error, {:authorization_unavailable, name}},
         {:oauth, _selected_names, _catalog}
       ),
       do: {:error, authorization_diagnostic(name)}

  defp registry_result(
         {:error, reason},
         {:oauth, selected_names, catalog}
       )
       when reason in [:operation_deadline_expired, :timeout] do
    name =
      selected_names
      |> Enum.filter(&(catalog.authorities[&1] != nil))
      |> Enum.min()

    {:error, authorization_diagnostic(name)}
  end

  defp registry_result({:error, _reason} = error, _operation), do: error

  defp close_memory(%Memory{pid: pid}) do
    if Process.alive?(pid), do: Memory.close(%Memory{pid: pid}), else: :ok
  end

  defp close_memory(memory, error) do
    close_memory(memory)
    error
  end

  defp close_unstarted_session(session, {:error, _reason} = error) do
    if is_nil(ProviderSession.run_deadline(session)), do: ProviderSession.close(session)
    error
  end

  defp close_unstarted_session(_session, result), do: result

  defp authorization_diagnostic(name) do
    {:ok, subject} = CommandSubject.provider(name, :authorization)

    CommandDiagnostic.new!(:active_preflight, :authorization_unavailable,
      provider_activity: true,
      subject: subject
    )
  end

  defp provider_application_mode do
    if :req_llm in started_applications(), do: :host_owned, else: :command_vm
  end

  # Dotenv discovery reads the filesystem and mutates the VM environment, so it
  # is command setup rather than bounded run work: it cannot be cancelled by a
  # deadline or rolled back, and an embedding must never acquire ambient `.env`
  # state implicitly inside the Kernel. The CLI therefore decides once, after
  # preparation has established which providers are selected and before any
  # execution owner, provider session, or run clock exists.
  defp load_environment_credentials(_prepared, %{host: nil}), do: :ok

  defp load_environment_credentials(prepared, runtime) do
    # Keyed on the declared credential, not on provider-application admission: a
    # direct `ollama:`/`openai-compat:` route needs no backing application but
    # can still resolve its credential from the nearest `.env`.
    if Enum.any?(prepared.provider_declarations, fn declaration ->
         with %{source: :llm, credential: credential} <-
                Map.get(runtime.host.install, declaration.name),
              %{source: :env} <- Map.get(runtime.host.credentials, credential) do
           true
         else
           _other -> false
         end
       end) do
      load_dotenv()
    else
      :ok
    end
  end

  # `PtcRunner.Dotenv` reads the file it finds with `File.read!/1`. Inside the
  # execution owner that raise became a closed internal diagnostic; in the
  # frontend it would otherwise put a raw exception and the `.env` path in the
  # command's failure output.
  defp load_dotenv do
    Dotenv.load()
  rescue
    _exception -> {:error, :dotenv_unavailable}
  catch
    _kind, _reason -> {:error, :dotenv_unavailable}
  end

  defp started_applications,
    do: Application.started_applications() |> Enum.map(&elem(&1, 0))

  defp validate_authorization_targets(_prepared, %{authorizations: []}), do: :ok

  defp validate_authorization_targets(prepared, runtime) do
    selected = MapSet.new(prepared.provider_declarations, & &1.name)

    if Enum.all?(runtime.authorizations, fn name ->
         MapSet.member?(selected, name) and
           match?(
             %{source: :mcp, transport: %{oauth: %Authority{}}},
             Map.get(runtime.host.install, name)
           )
       end) do
      :ok
    else
      {:error, :invalid_mcp_authorization}
    end
  end

  defp authorize_installations(
         host,
         context,
         registry,
         declarations,
         authorities,
         requested
       ) do
    Enum.reduce_while(requested, :ok, fn name, :ok ->
      case Map.get(host.install, name) do
        %{source: :mcp, transport: %{oauth: authority}} when not is_nil(authority) ->
          deadline =
            oauth_target_deadline(
              name,
              declarations,
              authorities,
              System.monotonic_time(:millisecond)
            )

          with true <- Deadline.valid?(deadline),
               {:ok, authority_epoch} <-
                 ProviderRegistry.oauth_authority_epoch(registry, name, deadline),
               :ok <- authorize_installation(context, authority, authority_epoch, deadline) do
            {:cont, :ok}
          else
            false ->
              {:halt, {:error, :invalid_mcp_authorization}}

            {:error, reason} when reason in [:timeout, :authorization_timeout] ->
              {:halt, {:error, {:authorization_timeout, name}}}

            {:error, :authorization_context_required} ->
              {:halt, {:error, {:authorization_unavailable, name}}}

            {:error, _reason} = error ->
              {:halt, error}
          end

        _missing_or_not_oauth ->
          {:halt, {:error, :invalid_mcp_authorization}}
      end
    end)
  end

  defp authorize_installation(context, authority, authority_epoch, deadline) do
    with true <- Authority.cli_compatible?(authority),
         {:ok, listener} <- LoopbackListener.start(authority) do
      authorize_with_listener(context, authority, authority_epoch, deadline, listener)
    else
      false -> {:error, :mcp_authorization_not_cli_compatible}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_with_listener(context, authority, authority_epoch, deadline, listener) do
    case Authorization.begin_authorization(context, authority,
           authority_epoch: authority_epoch,
           deadline_ms: Deadline.expires_at(deadline),
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
    |> Keyword.drop([
      :host_config,
      :authorize_mcp,
      :check,
      :mission,
      :private_mission,
      :component_override_descriptor
    ])
  end

  defp request(manifest, catalog, opts) do
    request_opts =
      [
        inspection_capture: Keyword.has_key?(opts, :inspect),
        input_authority: if(Keyword.has_key?(opts, :private_mission), do: :private, else: :normal)
      ]
      |> maybe_request_option(
        :input,
        Keyword.get(opts, :mission) || Keyword.get(opts, :private_mission)
      )
      |> maybe_request_option(
        :component_override_descriptor,
        Keyword.get(opts, :component_override_descriptor)
      )

    CommandEngine.request(manifest, catalog, request_opts)
  end

  defp maybe_request_option(opts, _key, nil), do: opts
  defp maybe_request_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp check(prepared, registry, session, host, opts) do
    result =
      if session,
        do: RunBuilder.build_active(prepared, registry, session, opts),
        else: RunBuilder.build_prepared(prepared, registry, opts)

    with {:ok, built} <- result do
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

  @max_failure_code_depth 3
  @max_failure_codes 4
  @persistence_failure_codes [
    :trace_persistence_failed,
    :inspection_persistence_failed,
    :result_persistence_failed
  ]

  @spec raise_failure(term()) :: no_return()
  defp raise_failure(error),
    do: Mix.raise("ptc.run failed: #{failure_message(error)}")

  @doc false
  @spec failure_message(term()) :: binary()
  def failure_message(%CommandDiagnostic{} = diagnostic) do
    if CommandDiagnostic.valid?(diagnostic) do
      "#{diagnostic.phase}/#{diagnostic.code}: #{diagnostic.message}"
    else
      "internal_error"
    end
  end

  def failure_message(error) do
    case error |> failure_codes(0) |> Enum.uniq() |> Enum.take(@max_failure_codes) do
      [] -> "internal_error"
      codes -> Enum.map_join(codes, "/", &Atom.to_string/1)
    end
  end

  defp failure_codes(value, _depth) when is_atom(value), do: [value]

  defp failure_codes(%{kind: kind, reason: reason}, _depth)
       when is_atom(kind) and is_atom(reason),
       do: [kind, reason]

  defp failure_codes(%{reason: reason}, _depth) when is_atom(reason), do: [reason]

  # Persistence failures carry the completed Kernel result in the third
  # position. It may contain private values and structural `:ok`/`:error`
  # tags, so only the first two code-owned positions are rendered.
  defp failure_codes({code, reason, _result}, depth)
       when code in @persistence_failure_codes and depth < @max_failure_code_depth,
       do: [code | failure_codes(reason, depth + 1)]

  defp failure_codes({code, reason}, depth)
       when is_atom(code) and depth < @max_failure_code_depth,
       do: [code | failure_codes(reason, depth + 1)]

  defp failure_codes({code, second, third}, _depth) when is_atom(code),
    do: Enum.filter([code, second, third], &is_atom/1)

  defp failure_codes({code, second, third, fourth}, _depth) when is_atom(code),
    do: Enum.filter([code, second, third, fourth], &is_atom/1)

  defp failure_codes(_value, _depth), do: []

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
