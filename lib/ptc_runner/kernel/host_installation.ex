defmodule PtcRunner.Kernel.HostInstallation do
  @moduledoc """
  Turns one strict host document into an inert installation catalog.

  The catalog contains exactly the aliases installed by the host document.
  Each alias pairs a sealed, declarative descriptor with a trusted
  implementation that phase 5 cannot inspect or invoke. Construction does not
  resolve credentials, inspect local paths, start applications, claim OAuth
  authority for a principal, or perform provider work. Manifest selections
  cannot fall back to implicit built-ins.

  Later runtime phases preflight local executable and launcher identity without
  reading credentials, then render credentials the command already resolved
  while acquiring the provider. An active command reads each declared credential
  exactly once, at phase-8 step 5; acquisition and the live connectivity probe
  both consume that value rather than resolving one of their own. Live LLM
  validation and optional public-identity attestation likewise precede
  credential access. Callback construction, provider-application readiness,
  and the adapter all receive the exact captured model value.
  Native trace acquisition
  exports its opaque frozen handle only to a selected inspection source, so
  private artifacts validate against the exact already-captured canonical
  source without reopening trace paths or exposing owner handles in metadata.
  An MCP installation containing any write mapping requires an explicit,
  nonempty manifest `allow` list before preflight, credential resolution, or
  transport acquisition. Omitting `allow` is permitted only for an all-read
  installation. Every stdio MCP child receives `LC_ALL=C.UTF-8`, independent
  of ambient locale and `inherit_environment`, so locale-sensitive servers
  encode protocol frames as UTF-8.

  Every public provider snapshot separates the safe declaration projection
  from bounded runtime-captured acquisition facts. `acquisition_identity_hash`
  covers the latter and bare-hex `snapshot_hash` covers both. An LLM adapter may
  explicitly attest its exact target as safe public identity; otherwise it is
  omitted. Unattested or private model targets, endpoints, commands, paths,
  credentials, and private OAuth authority never enter either projection. A
  frozen-content provider also
  publishes an algorithm-qualified `content_snapshot_hash`; native query
  results copy that content identity unchanged for citations.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallationAuthority
  alias PtcRunner.Kernel.HostRuntimePayload
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.LLMReplay
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.ManagerCleanup
  alias PtcRunner.Kernel.MCPOAuth.TokenManager
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSnapshot
  alias PtcRunner.Kernel.RunAnalysisCapability
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.Kernel.TraceSnapshot

  @inherited_compatibility_environment ~w(HOME LOGNAME PATH SHELL TERM USER)
  @stdio_locale_environment %{"LC_ALL" => "C.UTF-8"}
  @max_credential_bytes 65_536
  @max_executable_bytes 268_435_456
  @max_launcher_bytes 16_777_216
  @launcher_protocol_version 1

  @doc """
  Builds the inert declaration catalog installed by a loaded host document.

  Construction does not claim OAuth authorities, resolve credentials, inspect
  local paths, start applications, or invoke provider implementations.
  """
  @spec catalog(HostConfig.t()) ::
          {:ok, InstallationCatalog.t()} | {:error, :invalid_host_installation}
  def catalog(%HostConfig{} = host) do
    binding = runtime_binding(host)

    registrations =
      Enum.reduce_while(host.install, {:ok, %{}}, fn
        {name, installation}, {:ok, acc} ->
          case registration(name, installation, binding) do
            {:ok, registration} -> {:cont, {:ok, Map.put(acc, name, registration)}}
            {:error, _reason} -> {:halt, {:error, :invalid_host_installation}}
          end
      end)

    with {:ok, registrations} <- registrations,
         {:ok, catalog} <-
           InstallationCatalog.new(registrations,
             installed_limits: host.limits,
             runtime_binding: binding
           ) do
      {:ok, catalog}
    else
      _error -> {:error, :invalid_host_installation}
    end
  end

  def catalog(_host), do: {:error, :invalid_host_installation}

  @doc "Builds sealed active-runtime services for a loaded host document."
  @spec runtime_services(HostConfig.t(), keyword()) ::
          {:ok, ProviderRuntimeServices.t()} | {:error, :invalid_host_installation}
  def runtime_services(host, opts \\ [])

  def runtime_services(%HostConfig{} = host, opts) when is_list(opts) do
    with {:ok, payload} <- HostRuntimePayload.seal(host),
         {:ok, services} <- ProviderRuntimeServices.from_host_payload(payload, opts) do
      {:ok, services}
    else
      _invalid -> {:error, :invalid_host_installation}
    end
  end

  def runtime_services(_host, _opts), do: {:error, :invalid_host_installation}

  @doc false
  @spec runtime_registry(HostConfig.t(), InstallationCatalog.t()) ::
          {:ok, ProviderRegistry.t()} | {:error, atom()}
  def runtime_registry(%HostConfig{} = host, %InstallationCatalog{} = catalog) do
    with {:ok, services} <- runtime_services(host) do
      InstallationCatalog.runtime_registry(catalog, services)
    end
  end

  def runtime_registry(_host, _catalog), do: {:error, :invalid_provider_registry}

  defp runtime_binding(host), do: Attestation.attest(__MODULE__, host)

  defp registration(name, installation, binding) do
    authority = authority(installation)

    with {:ok, rules} <- selection_rules(installation),
         {:ok, descriptor} <- descriptor(installation, rules, authority) do
      implementation =
        %{builder: &inactive_runtime_builder/2}
        |> maybe_provider_application(installation)
        |> maybe_oauth_builder(installation)
        |> maybe_local_preflight(name, installation, binding)
        |> maybe_connectivity_probe(name, installation, binding)

      authority_binding = if authority, do: :host_runtime, else: nil

      {:ok,
       %{descriptor: descriptor, implementation: implementation, authority: authority_binding}}
    end
  end

  # Deliberately static. Catalog construction is an inert phase whose builder is
  # `inactive_runtime_builder/2`; asking the adapter here would execute
  # configurable code, and a raising registry or callback would escape as an
  # exception rather than `{:error, :invalid_host_installation}`. The cost is
  # that a direct `ollama:`/`openai-compat:` route is still admitted against
  # :req_llm, which is the long-standing behaviour rather than a regression. The
  # request-time check in `provider_application_ready/2` is route-aware, so the
  # error a caller actually sees is correct.
  defp maybe_provider_application(implementation, %{source: :llm}) do
    if Application.get_env(
         :ptc_runner,
         :llm_adapter,
         PtcRunner.LLM.ReqLLMAdapter
       ) == PtcRunner.LLM.ReqLLMAdapter,
       do: Map.put(implementation, :provider_application, :req_llm),
       else: implementation
  end

  defp maybe_provider_application(implementation, _installation), do: implementation

  defp maybe_oauth_builder(implementation, %{source: :mcp} = installation) do
    case authority(installation) do
      %Authority{} ->
        Map.put(implementation, :oauth_builder, &inactive_oauth_runtime_builder/3)

      nil ->
        implementation
    end
  end

  defp maybe_oauth_builder(implementation, _installation), do: implementation

  defp maybe_local_preflight(implementation, name, installation, binding) do
    if local_preflight_mode(installation) == :audited_local do
      Map.put(implementation, :local_preflight, fn selection, context, services ->
        ProviderRuntimeServices.host_call(
          services,
          binding,
          {:local_preflight, name, selection, context}
        )
      end)
    else
      implementation
    end
  end

  defp maybe_connectivity_probe(
         implementation,
         name,
         %{source: :llm},
         binding
       ) do
    Map.put(
      implementation,
      :connectivity_probe,
      fn selection, context, %ProviderRuntimeServices{} = services ->
        with {:ok, probe} <-
               ProviderRuntimeServices.host_call(
                 services,
                 binding,
                 {:connectivity_probe, name, selection, context}
               ) do
          run_llm_connectivity_probe(probe)
        end
      end
    )
  end

  defp maybe_connectivity_probe(implementation, _name, _installation, _binding),
    do: implementation

  defp inactive_runtime_builder(_selection, _context),
    do: {:error, :invalid_host_installation}

  defp inactive_oauth_runtime_builder(_selection, _context, _oauth_runtime),
    do: {:error, :invalid_host_installation}

  @doc false
  def runtime_builder(%HostInstallationAuthority{} = owner, name) when is_binary(name) do
    fn selection, context ->
      prepare_through_owner(owner, name, selection, context)
    end
  end

  defp prepare_through_owner(owner, name, selection, context) do
    case HostInstallationAuthority.invoke(owner, {:prepare, name, selection, context}) do
      {:ok, prepared} when is_map(prepared) ->
        requires_services? = Map.get(prepared, :requires, []) != []

        preflight = fn ->
          preflight_through_owner(owner, name, selection, context, requires_services?)
        end

        {:ok, Map.put(prepared, :preflight, preflight)}

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error, :invalid_host_installation}
    end
  end

  defp preflight_through_owner(owner, name, selection, context, requires_services?) do
    with {:ok, ticket} <-
           HostInstallationAuthority.invoke(owner, {:preflight, name, selection, context}) do
      acquisition_callbacks(owner, ticket, requires_services?)
    end
  end

  defp acquisition_callbacks(owner, ticket, true) do
    acquire = fn credentials, services ->
      HostInstallationAuthority.invoke(owner, {:acquire, ticket, credentials, services})
    end

    {:ok, acquire, cancel_preflight_callback(owner, ticket)}
  end

  defp acquisition_callbacks(owner, ticket, false) do
    acquire = fn credentials ->
      HostInstallationAuthority.invoke(owner, {:acquire, ticket, credentials, %{}})
    end

    {:ok, acquire, cancel_preflight_callback(owner, ticket)}
  end

  defp cancel_preflight_callback(owner, ticket),
    do: fn -> HostInstallationAuthority.invoke(owner, {:cancel_preflight, ticket}) end

  @doc false
  def owner_call(%HostConfig{} = host, {:prepare, name, selection, context, oauth_runtime}) do
    case Map.fetch(host.install, name) do
      {:ok, installation} -> prepare(host, installation, selection, context, oauth_runtime)
      :error -> {:error, :invalid_host_installation}
    end
  end

  def owner_call(%HostConfig{} = host, {:preflight, name, selection, context, oauth_runtime}) do
    case Map.fetch(host.install, name) do
      {:ok, installation} -> preflight(host, installation, selection, context, oauth_runtime)
      :error -> {:error, :invalid_host_installation}
    end
  end

  def owner_call(%HostConfig{} = host, {:local_preflight, name, selection, context}) do
    case Map.fetch(host.install, name) do
      {:ok, installation} -> local_preflight(host, installation, selection, context)
      :error -> {:error, :invalid_host_installation}
    end
  end

  def owner_call(%HostConfig{} = host, {:connectivity_probe, name, selection, context}) do
    case Map.fetch(host.install, name) do
      {:ok, %{source: :llm} = installation} ->
        prepare_llm_connectivity_probe(host, installation, selection, context)

      _missing_or_wrong_source ->
        {:error, :invalid_host_installation}
    end
  end

  def owner_call(%HostConfig{} = host, {:oauth_authorities, selected_names})
      when is_list(selected_names) and length(selected_names) <= 128 do
    if selected_names == Enum.uniq(selected_names) and
         Enum.all?(selected_names, &Map.has_key?(host.install, &1)) do
      authorities =
        Enum.reduce(selected_names, %{}, fn name, acc ->
          installation = Map.fetch!(host.install, name)

          case authority(installation) do
            %Authority{} = authority -> Map.put(acc, name, authority)
            nil -> acc
          end
        end)

      {:ok, authorities}
    else
      {:error, :invalid_host_installation}
    end
  end

  def owner_call(_host, _request), do: {:error, :invalid_host_installation}

  defp descriptor(installation, rules, authority) do
    ProviderDescriptor.new(
      source: installation.source,
      installation_revision: installation.installation_revision,
      credential_names: descriptor_credential_names(installation),
      authorization_mode: authorization_mode(installation),
      data_class: descriptor_data_class(installation),
      accepts_data:
        Map.get(installation, :accepts_data, snapshot_accepts_data(installation.source)),
      requires: descriptor_requires(installation.source),
      provides: descriptor_provides(installation.source),
      destinations: descriptor_destinations(installation.source),
      workflow_llm?: installation.source in [:llm, :llm_replay],
      connectivity_mode: connectivity_mode(installation.source),
      probe_effect: if(installation.source == :llm, do: :completion, else: nil),
      selection_validation: :declarative,
      selection_rules: rules,
      authority_fingerprint: if(authority, do: authority.fingerprint, else: nil),
      local_preflight: local_preflight_mode(installation)
    )
  end

  defp descriptor_credential_names(%{source: :mcp, transport: transport}) do
    case authority_from_transport(transport) do
      %Authority{} -> []
      nil -> credential_names(transport)
    end
  end

  defp descriptor_credential_names(%{source: :llm, credential: credential}), do: [credential]
  defp descriptor_credential_names(_installation), do: []

  defp descriptor_data_class(%{source: source})
       when source in [:ptc_private_trace_snapshot, :ptc_inspection_snapshot],
       do: :private_inspection

  defp descriptor_data_class(installation), do: Map.get(installation, :data_class, :normal)

  defp authorization_mode(%{source: :mcp, transport: transport}) do
    if match?(%Authority{}, authority_from_transport(transport)), do: :oauth, else: :none
  end

  defp authorization_mode(_installation), do: :none

  defp authority(%{source: :mcp, transport: transport}), do: authority_from_transport(transport)
  defp authority(_installation), do: nil

  defp authority_from_transport(%{oauth: %Authority{} = authority}), do: authority
  defp authority_from_transport(_transport), do: nil

  defp snapshot_accepts_data(source)
       when source in [
              :ptc_trace_snapshot,
              :ptc_private_trace_snapshot,
              :ptc_inspection_snapshot
            ],
       do: [:normal, :private_inspection]

  defp snapshot_accepts_data(_source), do: [:normal]

  defp descriptor_requires(:ptc_inspection_snapshot), do: [:canonical_trace_snapshot]
  defp descriptor_requires(_source), do: []

  defp descriptor_provides(source)
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot],
       do: [:canonical_trace_snapshot]

  defp descriptor_provides(_source), do: []

  defp descriptor_destinations(source) when source in [:llm, :llm_replay], do: [:workflow]
  defp descriptor_destinations(_source), do: [:mission]

  defp connectivity_mode(:mcp), do: :acquisition
  defp connectivity_mode(:llm), do: :probe
  defp connectivity_mode(_source), do: :none

  defp local_preflight_mode(%{source: :llm}), do: :audited_local
  defp local_preflight_mode(%{source: :mcp, transport: %{type: :stdio}}), do: :audited_local
  defp local_preflight_mode(%{source: :llm_replay}), do: :audited_local
  defp local_preflight_mode(_installation), do: :none

  defp selection_rules(%{source: :mcp} = installation) do
    public =
      installation.tools
      |> Map.values()
      |> Map.new(&{&1.as, &1})

    all = public |> Map.keys() |> Enum.sort()

    visible =
      public
      |> Enum.filter(fn {_name, mapping} -> mapping.model_visible end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    write =
      public
      |> Enum.reject(fn {_name, mapping} -> mapping.effect == :read end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    SelectionRules.new(
      fields: %{
        "allow" => %{
          type: {:unique_list, :string},
          input: true,
          default: {:named_set, "all"},
          minimum_items: 1,
          members: "all"
        },
        "max_result_bytes" => %{
          type: :integer,
          input: true,
          default: installation.ceilings.max_result_bytes,
          minimum: 1,
          maximum: installation.ceilings.max_result_bytes
        },
        "model_visible" => %{
          type: {:unique_list, :string},
          input: true,
          default: {:intersection, "allow", "visible"},
          members: "visible"
        },
        "timeout_ms" => %{
          type: :integer,
          input: true,
          default: installation.ceilings.timeout_ms,
          minimum: 1,
          maximum: installation.ceilings.timeout_ms
        }
      },
      cross_rules: [
        {:required_when_set_nonempty, "allow", "write"},
        {:subset_of, "model_visible", "allow"},
        {:ceiling_of_context_limit, "timeout_ms", :evaluation_timeout_ms},
        {:ceiling_of_context_limit, "max_result_bytes", :capability_result_bytes}
      ],
      named_sets: %{"all" => all, "visible" => visible, "write" => write}
    )
  end

  defp selection_rules(%{source: :llm} = installation) do
    SelectionRules.new(
      fields: %{
        "max_request_bytes" => %{
          type: :integer,
          input: true,
          default: installation.ceilings.max_request_bytes,
          minimum: 1,
          maximum: installation.ceilings.max_request_bytes
        },
        "max_response_bytes" => %{
          type: :integer,
          input: true,
          default: installation.ceilings.max_response_bytes,
          minimum: 1,
          maximum: installation.ceilings.max_response_bytes
        },
        "default" => %{
          type: :boolean,
          input: true,
          default: false
        }
      },
      cross_rules: [
        {:ceiling_of_context_limit, "max_request_bytes", :capability_argument_bytes},
        {:ceiling_of_context_limit, "max_response_bytes", :capability_result_bytes}
      ],
      named_sets: %{}
    )
  end

  defp selection_rules(%{source: :llm_replay} = installation) do
    SelectionRules.new(
      fields: %{
        "max_entries" => %{
          type: :integer,
          input: false,
          default: installation.ceilings.max_entries,
          minimum: 1,
          maximum: installation.ceilings.max_entries
        },
        "max_result_bytes" => %{
          type: :integer,
          input: true,
          default: installation.ceilings.max_result_bytes,
          minimum: 1,
          maximum: installation.ceilings.max_result_bytes
        },
        "default" => %{
          type: :boolean,
          input: true,
          default: false
        }
      },
      cross_rules: [
        {:ceiling_of_context_limit, "max_result_bytes", :capability_result_bytes}
      ],
      named_sets: %{}
    )
  end

  defp selection_rules(%{source: source} = installation)
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot] do
    snapshot_selection_rules(installation, false)
  end

  defp selection_rules(%{source: :ptc_inspection_snapshot} = installation) do
    snapshot_selection_rules(installation, true)
  end

  defp snapshot_selection_rules(installation, include_max_files?) do
    fields = %{
      "max_source_bytes" => %{
        type: :integer,
        input: true,
        default: installation.ceilings.max_source_bytes,
        minimum: 1,
        maximum: installation.ceilings.max_source_bytes
      },
      "max_result_bytes" => %{
        type: :integer,
        input: true,
        default: installation.ceilings.max_result_bytes,
        minimum: HostConfig.minimum_snapshot_result_bytes(),
        maximum: installation.ceilings.max_result_bytes
      }
    }

    fields =
      if include_max_files? do
        Map.put(fields, "max_files", %{
          type: :integer,
          input: true,
          default: installation.ceilings.max_files,
          minimum: 1,
          maximum: installation.ceilings.max_files
        })
      else
        Map.put(fields, "expose", %{type: :boolean, input: true, default: true})
      end

    SelectionRules.new(
      fields: fields,
      cross_rules: [
        {:ceiling_of_context_limit, "max_result_bytes", :capability_result_bytes}
      ],
      named_sets: %{}
    )
  end

  defp prepare(_host, %{source: :mcp} = installation, selection, context, _oauth_runtime) do
    with :ok <- placement(installation, context.destination),
         {:ok, _selected} <- normalize_selection(installation, selection, context) do
      credential_names = credential_names(installation.transport)

      {:ok,
       %{
         credential_names: credential_names,
         data_class: installation.data_class,
         accepts_data: installation.accepts_data
       }}
    end
  end

  defp prepare(_host, %{source: :llm} = installation, selection, context, _oauth_runtime) do
    credential_names = [installation.credential]

    with :ok <- placement(installation, context.destination),
         {:ok, selected} <- llm_selection(installation, selection, context) do
      {:ok,
       %{
         credential_names: credential_names,
         data_class: installation.data_class,
         accepts_data: installation.accepts_data,
         workflow_llm?: true,
         workflow_llm_route: workflow_llm_route(installation, selected)
       }}
    end
  end

  defp prepare(
         _host,
         %{source: :llm_replay} = installation,
         selection,
         context,
         _oauth_runtime
       ) do
    with :ok <- placement(installation, context.destination),
         {:ok, selected} <- llm_replay_selection(installation, selection, context) do
      {:ok,
       %{
         credential_names: [],
         data_class: installation.data_class,
         accepts_data: installation.accepts_data,
         workflow_llm?: true,
         workflow_llm_route: workflow_llm_route(installation, selected)
       }}
    end
  end

  defp prepare(
         _host,
         %{source: source} = installation,
         selection,
         context,
         _oauth_runtime
       )
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot] do
    with :ok <- placement(installation, context.destination),
         {:ok, _selected} <- trace_snapshot_selection(installation, selection, context) do
      {:ok,
       %{
         credential_names: [],
         data_class: descriptor_data_class(installation),
         accepts_data: [:normal, :private_inspection],
         provides: [:canonical_trace_snapshot]
       }}
    end
  end

  defp prepare(
         _host,
         %{source: :ptc_inspection_snapshot} = installation,
         selection,
         context,
         _oauth_runtime
       ) do
    with :ok <- placement(installation, context.destination),
         {:ok, _selected} <- inspection_snapshot_selection(installation, selection, context) do
      {:ok,
       %{
         credential_names: [],
         data_class: :private_inspection,
         accepts_data: [:normal, :private_inspection],
         requires: [:canonical_trace_snapshot]
       }}
    end
  end

  defp workflow_llm_route(installation, selected) do
    %{
      source: Atom.to_string(installation.source),
      installation_revision: installation.installation_revision,
      default: selected.default
    }
  end

  defp preflight(host, %{source: :mcp} = installation, selection, context, oauth_runtime) do
    with :ok <- placement(installation, context.destination),
         {:ok, selected} <- normalize_selection(installation, selection, context),
         credential_names = credential_names(installation.transport),
         {:ok, transport} <- preflight_transport(host, installation.transport),
         {:ok, installed_options} <-
           installed_options(installation, transport, credential_names) do
      {:ok,
       {:private_preflight,
        fn credentials ->
          acquire(
            installation,
            installed_options,
            transport,
            selected,
            context,
            credentials,
            oauth_runtime
          )
        end}}
    end
  end

  defp preflight(_host, %{source: :llm} = installation, selection, context, _oauth_runtime) do
    with :ok <- placement(installation, context.destination),
         {:ok, selected} <- llm_selection(installation, selection, context),
         {:ok, model, adapter} <- preflight_llm(installation.model),
         {:ok, prepared_model} <- prepare_llm_model(model, adapter) do
      public_model = PtcRunner.LLM.attested_public_model(adapter, model)

      {:ok,
       {:private_preflight,
        fn credentials ->
          acquire_llm(
            installation,
            selected,
            context,
            model,
            prepared_model,
            public_model,
            adapter,
            credentials
          )
        end}}
    end
  end

  defp preflight(
         host,
         %{source: :llm_replay} = installation,
         selection,
         context,
         _oauth_runtime
       ) do
    with :ok <- placement(installation, context.destination),
         {:ok, selected} <- llm_replay_selection(installation, selection, context) do
      {:ok,
       {:private_preflight,
        fn _credentials -> acquire_llm_replay(host, installation, selected, context) end}}
    end
  end

  defp preflight(
         host,
         %{source: source} = installation,
         selection,
         context,
         _oauth_runtime
       )
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot] do
    with :ok <- placement(installation, context.destination),
         {:ok, selected} <- trace_snapshot_selection(installation, selection, context),
         {:ok, directory} <-
           canonical_snapshot_directory(host.directory, installation.directory) do
      {:ok,
       {:private_preflight,
        fn %{} -> acquire_trace_snapshot(directory, installation, selected, context) end}}
    end
  end

  defp preflight(
         host,
         %{source: :ptc_inspection_snapshot} = installation,
         selection,
         context,
         _oauth_runtime
       ) do
    with :ok <- placement(installation, context.destination),
         {:ok, selected} <- inspection_snapshot_selection(installation, selection, context),
         {:ok, directory} <-
           canonical_inspection_snapshot_directory(host.directory, installation.directory) do
      {:ok,
       {:private_preflight,
        fn %{}, %{canonical_trace_snapshot: trace_snapshot} ->
          acquire_inspection_snapshot(
            directory,
            trace_snapshot,
            installation,
            selected,
            context
          )
        end}}
    end
  end

  # Adapter preparation has a deliberately rich direct-embedding error
  # vocabulary. An installed provider crosses the Kernel's closed diagnostic
  # boundary instead, where every invalid or unsupported target is represented
  # by the existing adapter-unavailable reason.
  defp prepare_llm_model(model, adapter) do
    case PtcRunner.LLM.prepare(model, adapter) do
      {:ok, prepared_model} -> {:ok, prepared_model}
      {:error, _reason} -> {:error, :invalid_llm_model}
    end
  end

  defp placement(%{source: :mcp}, :mission), do: :ok
  defp placement(%{source: :mcp}, _destination), do: {:error, :provider_destination_denied}
  defp placement(%{source: :llm}, :workflow), do: :ok
  defp placement(%{source: :llm}, _destination), do: {:error, :provider_destination_denied}
  defp placement(%{source: :llm_replay}, :workflow), do: :ok

  defp placement(%{source: :llm_replay}, _destination),
    do: {:error, :provider_destination_denied}

  defp placement(%{source: source}, :mission)
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot],
       do: :ok

  defp placement(%{source: source}, _destination)
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot],
       do: {:error, :provider_destination_denied}

  defp placement(%{source: :ptc_inspection_snapshot}, :mission), do: :ok

  defp placement(%{source: :ptc_inspection_snapshot}, _destination),
    do: {:error, :provider_destination_denied}

  @doc false
  def normalize_selection(%{source: source} = installation, value, %{limits: limits})
      when source in [
             :mcp,
             :llm,
             :llm_replay,
             :ptc_trace_snapshot,
             :ptc_private_trace_snapshot,
             :ptc_inspection_snapshot
           ] do
    with {:ok, rules} <- selection_rules(installation),
         {:ok, normalized} <- SelectionRules.normalize_runtime(rules, value, limits) do
      {:ok, normalized}
    else
      _reason -> {:error, selection_error(source)}
    end
  end

  def normalize_selection(_installation, _value, _context),
    do: {:error, :invalid_mcp_selection}

  defp llm_selection(installation, value, context),
    do: normalize_runtime_selection(installation, value, context)

  defp llm_replay_selection(installation, value, context),
    do: normalize_runtime_selection(installation, value, context)

  defp trace_snapshot_selection(installation, value, context),
    do: normalize_runtime_selection(installation, value, context)

  defp inspection_snapshot_selection(installation, value, context),
    do: normalize_runtime_selection(installation, value, context)

  defp normalize_runtime_selection(installation, value, context) do
    with {:ok, normalized} <- normalize_selection(installation, value, context) do
      {:ok, Map.new(normalized, fn {key, item} -> {String.to_existing_atom(key), item} end)}
    end
  end

  defp selection_error(:mcp), do: :invalid_mcp_selection
  defp selection_error(:llm), do: :invalid_llm_selection
  defp selection_error(:llm_replay), do: :invalid_llm_replay_selection
  defp selection_error(:ptc_trace_snapshot), do: :invalid_trace_snapshot_selection
  defp selection_error(:ptc_private_trace_snapshot), do: :invalid_trace_snapshot_selection
  defp selection_error(:ptc_inspection_snapshot), do: :invalid_inspection_snapshot_selection

  defp credential_names(%{type: :stdio, env: env}),
    do: env |> Map.values() |> Enum.uniq() |> Enum.sort()

  defp credential_names(%{type: :streamable_http, auth: auth}),
    do: auth |> Enum.map(& &1.binding) |> Enum.uniq() |> Enum.sort()

  defp local_preflight(host, %{source: :mcp} = installation, selection, context) do
    with :ok <- placement(installation, context.destination),
         {:ok, _selected} <- normalize_selection(installation, selection, context),
         {:ok, transport} <- preflight_transport(host, installation.transport),
         {:ok, _options} <-
           installed_options(installation, transport, credential_names(installation.transport)) do
      :ok
    end
  end

  defp local_preflight(_host, %{source: :llm} = installation, selection, context) do
    with :ok <- placement(installation, context.destination),
         {:ok, _selected} <- llm_selection(installation, selection, context),
         {:ok, _model, _adapter} <- preflight_llm(installation.model) do
      :ok
    end
  end

  defp local_preflight(host, %{source: :llm_replay} = installation, selection, context) do
    with :ok <- placement(installation, context.destination),
         {:ok, selected} <- llm_replay_selection(installation, selection, context),
         {:ok, _summary} <-
           LLMReplay.probe(host.directory, installation.fixtures,
             max_entries: selected.max_entries,
             max_result_bytes: selected.max_result_bytes
           ) do
      :ok
    end
  end

  # The credential arrives already resolved: phase-8 step 5 reads it once per
  # command from the sealed declarations, before any probe or provider callback
  # runs, so a probe that resolved its own would be a second read outside that
  # step's budget and attribution.
  defp prepare_llm_connectivity_probe(_host, installation, selection, context) do
    with :ok <- placement(installation, context.destination),
         {:ok, _selected} <- llm_selection(installation, selection, context),
         {:ok, model, adapter} <- preflight_llm(installation.model),
         {:ok, prepared_model} <- prepare_llm_model(model, adapter),
         {:ok, credential} <-
           Map.fetch(Map.get(context, :credentials, %{}), installation.credential),
         {:ok, timeout_ms, max_heap_words} <- connectivity_probe_bounds(context) do
      {:ok,
       %{
         model: model,
         prepared_model: prepared_model,
         adapter: adapter,
         credential: credential,
         params: installation.params,
         timeout_ms: timeout_ms,
         max_heap_words: max_heap_words
       }}
    else
      _reason -> {:error, :llm_connectivity_unavailable}
    end
  end

  defp connectivity_probe_bounds(%{limits: limits} = context) do
    with timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 <-
           Map.get(limits, :doctor_connectivity_timeout_ms),
         max_heap_words when is_integer(max_heap_words) and max_heap_words > 0 <-
           Map.get(limits, :provider_heap_words) do
      timeout_ms =
        case Map.get(context, :doctor_occurrence_deadline_ms) do
          deadline when is_integer(deadline) ->
            min(timeout_ms, deadline - System.monotonic_time(:millisecond))

          nil ->
            timeout_ms

          _invalid ->
            0
        end

      if timeout_ms > 0,
        do: {:ok, timeout_ms, max_heap_words},
        else: {:error, :llm_connectivity_unavailable}
    else
      _invalid -> {:error, :llm_connectivity_unavailable}
    end
  end

  defp connectivity_probe_bounds(_context), do: {:error, :llm_connectivity_unavailable}

  defp run_llm_connectivity_probe(probe) do
    options =
      probe.params
      |> Map.to_list()
      |> Keyword.merge(
        adapter: probe.adapter,
        api_key: probe.credential,
        cache: false,
        max_tokens: 1,
        max_retries: 0,
        receive_timeout: probe.timeout_ms,
        req_http_options: [retry: false, redirect: false, max_retries: 0]
      )

    case PtcRunner.LLM.callback(probe.prepared_model, options) do
      {:ok, requester} ->
        result =
          BoundedWorker.run(
            fn ->
              requester.(%{
                messages: [%{role: :user, content: "Health check."}],
                cache: false
              })
            end,
            timeout_ms: probe.timeout_ms,
            max_heap_words: probe.max_heap_words,
            cancel_with_caller: true
          )

        case result do
          {:ok, {:ok, response}} when is_map(response) -> :ok
          _failure -> {:error, :llm_connectivity_unavailable}
        end

      {:error, _reason} ->
        {:error, :llm_connectivity_unavailable}
    end
  rescue
    _exception -> {:error, :llm_connectivity_unavailable}
  catch
    _kind, _reason -> {:error, :llm_connectivity_unavailable}
  end

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

  # The decoded loopback allowance travels with the endpoint it was declared
  # against, so the source re-applies the rule the host document was already
  # checked with instead of defaulting to a stricter one and rejecting a
  # transport decoding admitted. An OAuth or `auth`-bearing installation never
  # carries it: `HostConfig` refuses a credential over plain HTTP.
  defp http_transport_options(transport, extra) when is_list(extra) do
    {:streamable_http,
     [
       endpoint: transport.endpoint,
       allow_insecure_loopback: transport.allow_insecure_loopback
     ] ++ extra}
  end

  defp installed_options(installation, transport, _credential_names) do
    options = [
      tools: installation.tools,
      timeout_ms: installation.ceilings.timeout_ms,
      max_result_bytes: installation.ceilings.max_result_bytes,
      max_catalog_tools: installation.ceilings.max_catalog_tools,
      snapshot_identity: installation.snapshot_identity,
      installation_revision: installation.installation_revision
    ]

    case transport.type do
      :streamable_http ->
        try do
          _builder =
            MCPSource.builder([
              {:transport, http_transport_options(transport, headers: fn -> [] end)} | options
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
         credentials,
         nil
       ) do
    with {:ok, headers} <- render_headers(transport.auth, credentials) do
      options =
        [transport: http_transport_options(transport, headers: fn -> headers end)] ++ options

      MCPSource.acquire(options, selected, context)
      |> classify(installation, selected, context.provider)
    end
  end

  defp acquire(
         installation,
         options,
         %{type: :streamable_http} = transport,
         selected,
         context,
         credentials,
         %{authority: authority, authority_epoch: authority_epoch, context: authorization_context}
       ) do
    with %{} <- credentials,
         {:ok, manager} <-
           TokenManager.start(
             owner: context.owner,
             resource_registrar: Map.get(context, :resource_registrar),
             context: authorization_context,
             authority: authority,
             authority_epoch: authority_epoch
           ) do
      source_options =
        [transport: http_transport_options(transport, authorization: manager)] ++ options

      result =
        MCPSource.acquire(source_options, selected, context)
        |> classify(installation, selected, context.provider)

      case result do
        {:ok, _provider} = success ->
          success

        error ->
          case ManagerCleanup.adopt(manager, Map.get(context, :resource_registrar)) do
            :ok ->
              error

            {:error, :cleanup_unavailable} ->
              Process.exit(manager.pid, :kill)
              {:error, :mcp_transport_error}

            {:error, :scope_unavailable} ->
              {:error, :mcp_transport_error}
          end
      end
    else
      {:error, :resource_registrar_unavailable} -> {:error, :mcp_transport_error}
      _invalid -> {:error, :mcp_authorization_required}
    end
  end

  defp acquire(
         installation,
         options,
         %{type: :stdio} = transport,
         selected,
         context,
         credentials,
         _oauth_runtime
       ) do
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

      MCPSource.acquire(
        [transport: {:stdio, transport_options}] ++ options,
        selected,
        context
      )
      |> classify(installation, selected, context.provider)
    end
  end

  # A model is a full provider-qualified identifier such as
  # "openrouter:deepseek/deepseek-v4-flash". Requiring the provider prefix
  # here keeps a mistyped host entry a bounded preflight failure instead of a
  # live provider call that fails after the run clock has started. The adapter
  # remains the authority on whether the provider and model actually exist.
  @model_pattern ~r/\A[a-z][a-z0-9_-]*:\S/

  defp preflight_llm(model) do
    with true <- is_binary(model) and byte_size(model) in 1..256,
         true <- String.valid?(model),
         true <- Regex.match?(@model_pattern, model),
         adapter when is_atom(adapter) <- PtcRunner.LLM.adapter!(),
         true <- Code.ensure_loaded?(adapter) do
      {:ok, model, adapter}
    else
      _invalid -> {:error, :invalid_llm_model}
    end
  rescue
    _exception -> {:error, :invalid_llm_model}
  end

  defp acquire_llm(
         installation,
         selected,
         context,
         model,
         prepared_model,
         public_model,
         adapter,
         credentials
       ) do
    with {:ok, credential} <- Map.fetch(credentials, installation.credential),
         {:ok, requester} <-
           PtcRunner.LLM.callback(
             prepared_model,
             [
               adapter: adapter,
               cache: installation.cache,
               api_key: credential
             ] ++ Map.to_list(installation.params)
           ),
         {:ok, capability} <-
           LLMCapability.new(
             requester: fn request ->
               with :ok <- provider_application_ready(adapter, model) do
                 request
                 |> ProviderRegistry.adapter_request()
                 |> requester.()
               end
             end,
             max_request_bytes: selected.max_request_bytes,
             max_response_bytes: selected.max_response_bytes
           ),
         {:ok, snapshot} <-
           llm_snapshot(installation, selected, context.provider, public_model) do
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

  # The core no longer starts an adapter's backing application on a host's
  # behalf; a run admits it through ProviderApplicationGate. An embedding host
  # that drives the registry directly can reach a request with that application
  # still stopped, where the failure would otherwise read as a retryable
  # `:unavailable` provider outage. Retrying cannot start an OTP application, so
  # name the real cause and mark it final.
  #
  # This is checked BEFORE invoking the adapter rather than by classifying its
  # result: an application that was started and later stopped leaves the adapter
  # raising (its registry is gone) instead of returning an error tuple, and a
  # raise would unwind straight past any post-hoc classification.
  defp provider_application_ready(adapter, model) do
    case provider_application(adapter, model) do
      nil ->
        :ok

      application ->
        if Enum.any?(Application.started_applications(), &(elem(&1, 0) == application)) do
          :ok
        else
          {:error,
           ProviderError.new(
             :internal,
             "the #{application} provider application is not started; " <>
               "start it before building this provider, or run through the " <>
               "prepared-run path that admits it",
             retryable?: false
           )}
        end
    end
  end

  # `adapter` is always the module resolved by PtcRunner.LLM.adapter!/0, so no
  # non-atom clause is reachable here.
  defp provider_application(adapter, model) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :provider_application, 1),
      do: adapter.provider_application(model),
      else: nil
  end

  defp acquire_llm_replay(host, installation, selected, context) do
    with {:ok, replay} <-
           LLMReplay.start(host.directory, installation.fixtures,
             max_entries: selected.max_entries,
             max_result_bytes: selected.max_result_bytes,
             owner: context.owner,
             resource_registrar: Map.get(context, :resource_registrar)
           ),
         {:ok, capability} <-
           LLMCapability.new(
             requester: LLMReplay.requester(replay),
             max_response_bytes: selected.max_result_bytes
           ),
         {:ok, snapshot} <- llm_replay_snapshot(replay, installation, context.provider) do
      {:ok,
       %{
         capabilities: [capability],
         snapshot: snapshot,
         close: fn -> LLMReplay.stop(replay) end,
         data_class: installation.data_class,
         accepts_data: installation.accepts_data
       }}
    end
  end

  defp llm_replay_snapshot(replay, installation, provider) do
    acquisition = LLMReplay.snapshot(replay)
    content_snapshot_hash = acquisition["fixture_set_hash"]

    public_snapshot(
      installation,
      provider,
      %{
        "max_entries" => installation.ceilings.max_entries,
        "max_result_bytes" => acquisition["max_result_bytes"]
      },
      acquisition,
      content_snapshot_hash
    )
  end

  defp acquire_trace_snapshot(directory, installation, selected, context) do
    case TraceSnapshot.start(trace_snapshot_source(installation.source, directory),
           owner: context.owner,
           resource_registrar: Map.get(context, :resource_registrar),
           max_source_bytes: selected.max_source_bytes,
           max_result_bytes: selected.max_result_bytes
         ) do
      {:ok, snapshot} ->
        finish_trace_snapshot(snapshot, installation, selected, context.provider)

      {:error, _reason} = error ->
        error
    end
  end

  defp finish_trace_snapshot(snapshot, installation, selected, provider) do
    with {:ok, capabilities} <- trace_analysis_capabilities(snapshot, selected, provider),
         {:ok, info} <- TraceSnapshot.info(snapshot),
         {:ok, provider_snapshot} <-
           trace_provider_snapshot(info, installation, selected, provider) do
      {:ok,
       %{
         capabilities: capabilities,
         snapshot: provider_snapshot,
         close: fn ->
           TraceSnapshot.stop(snapshot)
           :ok
         end,
         data_class: descriptor_data_class(installation),
         accepts_data: [:normal, :private_inspection],
         exports: %{canonical_trace_snapshot: snapshot}
       }}
    else
      {:error, _reason} = error ->
        TraceSnapshot.stop(snapshot)
        error
    end
  end

  defp trace_analysis_capabilities(snapshot, %{expose: true}, provider),
    do: RunAnalysisCapability.from_snapshots(snapshot, nil, provider)

  defp trace_analysis_capabilities(_snapshot, %{expose: false}, _provider), do: {:ok, []}

  defp acquire_inspection_snapshot(
         directory,
         trace_snapshot,
         installation,
         selected,
         context
       ) do
    case InspectionSnapshot.start({:directory, directory}, trace_snapshot,
           owner: context.owner,
           resource_registrar: Map.get(context, :resource_registrar),
           max_files: selected.max_files,
           max_source_bytes: selected.max_source_bytes,
           max_result_bytes: selected.max_result_bytes
         ) do
      {:ok, snapshot} ->
        finish_inspection_snapshot(
          snapshot,
          trace_snapshot,
          installation,
          selected,
          context.provider
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp finish_inspection_snapshot(snapshot, trace_snapshot, installation, selected, provider) do
    with {:ok, capabilities} <-
           RunAnalysisCapability.from_snapshots(trace_snapshot, snapshot, provider),
         {:ok, info} <- InspectionSnapshot.info(snapshot),
         {:ok, provider_snapshot} <-
           inspection_provider_snapshot(info, installation, selected, provider) do
      {:ok,
       %{
         capabilities: capabilities,
         snapshot: provider_snapshot,
         close: fn ->
           InspectionSnapshot.stop(snapshot)
           :ok
         end,
         data_class: :private_inspection,
         accepts_data: [:normal, :private_inspection]
       }}
    else
      {:error, _reason} = error ->
        InspectionSnapshot.stop(snapshot)
        error
    end
  end

  defp inspection_provider_snapshot(info, installation, selected, provider) do
    acquisition = %{
      "source" => "ptc_inspection_snapshot",
      "capture_id" => info.capture_id,
      "trace_capture_id" => info.trace_capture_id,
      "file_count" => info.file_count,
      "run_count" => info.run_count,
      "source_bytes" => info.source_bytes,
      "retained_bytes" => info.retained_bytes
    }

    public_snapshot(
      installation,
      provider,
      selected,
      acquisition,
      info.snapshot_hash
    )
  end

  defp trace_provider_snapshot(info, installation, selected, provider) do
    acquisition = %{
      "source" => Atom.to_string(installation.source),
      "capture_id" => info.capture_id,
      "run_count" => info.run_count,
      "source_bytes" => info.source_bytes,
      "retained_bytes" => info.retained_bytes
    }

    public_snapshot(
      installation,
      provider,
      selected,
      acquisition,
      info.snapshot_hash
    )
  end

  defp trace_snapshot_source(:ptc_trace_snapshot, directory), do: {:directory, directory}

  defp trace_snapshot_source(:ptc_private_trace_snapshot, directory),
    do: {:private_authorized_directory, directory}

  defp llm_snapshot(installation, selected, provider, public_model) do
    acquisition =
      %{"source" => "llm"}
      |> maybe_put_resolved_model(public_model)

    public_snapshot(
      installation,
      provider,
      selected,
      acquisition,
      nil
    )
  end

  defp maybe_put_resolved_model(acquisition, nil), do: acquisition

  defp maybe_put_resolved_model(acquisition, model),
    do: Map.put(acquisition, "resolved_model", model)

  defp classify({:ok, built}, installation, selected, provider) do
    acquisition =
      Map.take(
        built.snapshot,
        ~w(
          launcher_protocol_version
          launcher_sha256
          protocol
          server_executable_sha256
          server_info_hash
          tools
          transport
        )
      )

    content_snapshot_hash = Map.get(built.snapshot, "content_snapshot_hash")

    with {:ok, snapshot} <-
           public_snapshot(
             installation,
             provider,
             selected,
             acquisition,
             content_snapshot_hash
           ) do
      {:ok,
       built
       |> Map.put(:snapshot, snapshot)
       |> Map.put(:data_class, installation.data_class)
       |> Map.put(:accepts_data, installation.accepts_data)}
    end
  end

  defp classify({:error, _reason} = error, _installation, _selected, _provider), do: error

  defp public_snapshot(installation, provider, selected, acquisition, content_snapshot_hash) do
    with {:ok, rules} <- selection_rules(installation),
         {:ok, descriptor} <- descriptor(installation, rules, authority(installation)) do
      ProviderSnapshot.build(
        descriptor,
        provider,
        string_keyed(selected),
        acquisition,
        content_snapshot_hash
      )
    else
      _invalid -> {:error, :invalid_provider_snapshot}
    end
  end

  defp string_keyed(value) when is_map(value) do
    Map.new(value, fn
      {key, item} when is_atom(key) -> {Atom.to_string(key), item}
      {key, item} when is_binary(key) -> {key, item}
    end)
  end

  defp compatibility_environment(false), do: {:ok, @stdio_locale_environment}

  defp compatibility_environment(true) do
    Enum.reduce_while(
      @inherited_compatibility_environment,
      {:ok, @stdio_locale_environment},
      fn name, {:ok, environment} ->
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
      end
    )
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

  defp canonical_snapshot_directory(base, path) do
    candidate = if Path.type(path) == :absolute, do: path, else: Path.expand(path, base)

    with {:ok, canonical} <- ConfinedFile.resolve_absolute(candidate),
         {:ok, %{type: :directory}} <- File.stat(canonical) do
      {:ok, canonical}
    else
      _reason -> {:error, :invalid_trace_snapshot_directory}
    end
  end

  defp canonical_inspection_snapshot_directory(base, path) do
    candidate = if Path.type(path) == :absolute, do: path, else: Path.expand(path, base)

    with {:ok, canonical} <- ConfinedFile.resolve_absolute(candidate),
         {:ok, %{type: :directory}} <- File.stat(canonical) do
      {:ok, canonical}
    else
      _reason -> {:error, :invalid_inspection_snapshot_directory}
    end
  end

  defp resolve_command(command, environment) do
    case Path.type(command) do
      :absolute ->
        canonical_mcp_executable(command)

      :relative ->
        if Path.basename(command) == command do
          resolve_bare_command(command, Map.get(environment, "PATH"))
        else
          {:error, :invalid_mcp_executable}
        end
    end
  end

  defp resolve_bare_command(_command, nil), do: {:error, :mcp_command_not_found}

  defp resolve_bare_command(command, path) do
    path
    |> String.split(":", trim: true)
    |> Enum.reduce_while({:error, :mcp_command_not_found}, fn directory, previous_error ->
      if Path.type(directory) == :absolute do
        case canonical_mcp_executable(Path.join(directory, command)) do
          {:ok, _path, _digest} = success -> {:halt, success}
          {:error, :mcp_command_not_found} -> {:cont, previous_error}
          {:error, :invalid_mcp_executable} = error -> {:cont, error}
        end
      else
        {:cont, previous_error}
      end
    end)
  end

  defp canonical_mcp_executable(path) do
    case ConfinedFile.resolve_absolute(path) do
      {:ok, canonical} ->
        case validate_executable(canonical, @max_executable_bytes) do
          {:ok, digest} -> {:ok, canonical, digest}
          {:error, _reason} -> {:error, :invalid_mcp_executable}
        end

      {:error, :not_found} ->
        {:error, :mcp_command_not_found}

      {:error, _reason} ->
        {:error, :invalid_mcp_executable}
    end
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
         {:ok, digest} <- validate_executable(canonical, max_bytes) do
      {:ok, canonical, digest}
    else
      _reason -> {:error, error}
    end
  end

  defp validate_executable(canonical, max_bytes) do
    with {:ok, stat} <- File.stat(canonical),
         true <- stat.type == :regular and stat.size in 1..max_bytes,
         true <- Bitwise.band(stat.mode, 0o111) != 0,
         {:ok, digest} <- hash_file(canonical, max_bytes) do
      {:ok, digest}
    else
      _invalid -> {:error, :invalid_executable}
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

  @doc false
  @spec resolve_runtime_credentials(HostConfig.t(), [binary()]) ::
          {:ok, %{binary() => binary()}} | {:error, :credential_unavailable}
  def resolve_runtime_credentials(%HostConfig{} = host, names) when is_list(names) do
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

  def resolve_runtime_credentials(_host, _names), do: {:error, :credential_unavailable}

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
end
