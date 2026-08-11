defmodule PtcRunner.Kernel.ProviderAcquisition do
  @moduledoc """
  Acquires one prepared run's selected providers through its active session.

  The acquisition barrier prepares the planned providers, completes local
  preflight, and then acquires them in dependency order. Each acquired provider
  is committed to its provisional registrar immediately, before the next
  provider can run.

  `acquire/6` is the entry every provider-acquiring run uses and also serves
  acquisition-mode occurrences under `doctor --connect`. Connectivity has its
  own sealed completion while sharing the surrounding active-session ownership.
  Acquisition plans from sealed evidence: the preparation phase 5
  produced and the exact catalog it was validated against, which together
  supply the dependency graph that decides the closure and the
  whole-application judgements already made over the complete selection.
  Nothing about which callbacks run is derived from what a callback reported.

  Credentials are supplied, not resolved here. An active command resolves them
  once at phase-8 step 5 from its sealed declarations, before any provider
  callback runs, and hands the map down. Each provider receives only the names
  its own *sealed declaration* names, because a preparation that reports
  anything else — including a name a different selected provider declared —
  fails closed before the supplied map is consulted at all.

  For an active command, provider preparation, preflight, and acquisition run in
  owner-linked bounded work using the remaining shared run deadline and provider
  heap limit. Preflight releases use one shared provider-cleanup budget.

  `acquire_embedded/5` is the direct embedding entry. It has no preparation, no
  catalog, and no operation deadline, so it has no sealed declaration to compare
  a preparation against and no union to resolve before one runs: it decides the
  whole-application judgements from the preparations themselves and lets the
  registry resolve credentials synchronously, which is the contract
  `ProviderRegistry` documents for that caller.

  This module does not own the provider session. Its caller closes that session
  after any error and retains it with a successful acquisition result.
  """

  alias PtcRunner.Kernel.AcquisitionReason
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderCallbackBoundary
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar

  @type input_class :: :normal | :private_inspection
  @type artifact_preflight :: (input_class() -> :ok | {:error, term()})
  @type occurrence :: %{destination: :workflow | :mission, index: non_neg_integer()}
  @type targets :: [occurrence()] | :all
  @type result ::
          {:ok, map()}
          | {:error, term()}
          | {:unregistered_provider_close, term(), ProviderRegistry.close()}

  @doc """
  Acquires the sealed acquisition targets of one prepared run, and nothing else.

  A provider the sealed declarations did not name — directly or as a dependency
  — stays completely callback-inert: not prepared, not preflighted, not asked
  for credentials, not acquired. Preparation is provider work, not a lookup. A
  prepare callback can fail the whole operation, block until the deadline, spend
  the budget a real target needed, and register provisional roots that outlive
  it, so "prepare everything and then narrow" narrows nothing that matters.

  The plan is therefore projected here from sealed evidence rather than handed
  in: `prepared` and `catalog` must be the pair phase 5 validated together, and
  `session` must be the one opened for that preparation. Those three checks are
  what bind the plan to the operation it runs under; a preparation and catalog
  legitimately sealed for a *different* operation cannot decide which callbacks
  run under this one, even when both applications share a package digest.
  Deriving the closure from callback-reported `requires`/`provides` instead
  would make the authority to invoke a callback depend on invoking callbacks,
  and would let executable code redirect which executable code runs.

  `targets` is `:all` for a run, which acquires the whole selection, or the
  `{destination, index}` occurrences connectivity answers for — the same
  identity the sealed declarations and `ConnectivityResult` use. They are
  checked against the sealed occurrences before any callback runs, so an unknown
  or empty target set costs nothing.

  Inside the closure, each preparation is compared with its sealed declaration
  and drift fails closed. Dependency-only providers are support work: acquired
  and cleaned up like any other, and never reported as a caller's own result.

  The whole-application judgements need no re-derivation. Phase 5 decided
  dependency validity, cycles, workflow-LLM default uniqueness, the effective data
  class, and the providers' acceptance of it inertly over the complete
  selection, and sealed the result — an application whose classes disagree never
  becomes a preparation at all.

  `credentials` is the map phase-8 step 5 resolved for the whole selection. It
  is deliberately wider than this closure: connectivity must answer for every
  selected occurrence, including ones no closure reaches.
  """
  @spec acquire(
          PreparedRun.t(),
          InstallationCatalog.t(),
          ProviderRegistry.t(),
          ProviderSession.t(),
          targets(),
          %{binary() => binary()}
        ) :: result()
  def acquire(
        %PreparedRun{} = prepared,
        %InstallationCatalog{} = catalog,
        %ProviderRegistry{} = registry,
        session,
        targets,
        credentials
      )
      when (is_list(targets) or targets == :all) and is_map(credentials) and
             not is_struct(credentials) do
    package = prepared.request.package
    max_heap_words = package.limits.provider_heap_words

    with :ok <- bound(prepared, catalog, session),
         {:ok, occurrences} <- sealed_occurrences(prepared, catalog),
         {:ok, closure} <- sealed_closure(occurrences, targets),
         {:ok, preparations} <-
           prepare_providers(package, registry, session, max_heap_words, closure),
         :ok <- declarations_honored(preparations, closure, session) do
      complete_acquisition(
        preparations,
        registry,
        session,
        prepared.effective_data_class,
        max_heap_words,
        credentials
      )
    end
  end

  def acquire(_prepared, _catalog, _registry, _session, _targets, _credentials),
    do: {:error, :invalid_provider_acquisition}

  @doc """
  Acquires every selected provider of a direct embedding build.

  An embedding never crossed phases 4 and 5, so this entry has no preparation to
  plan from and no catalog to read a descriptor out of. The whole-application
  judgements are therefore derived from the preparations themselves, the
  effective data class is folded from the caller's input class, and credentials
  are resolved synchronously by the registry once every provider has
  preflighted.

  What tells an embedding apart from an active command is that its session
  carries no operation identity and no operation deadline, and that is asked
  once, here, before any callback runs. An active command reaching this entry
  would otherwise spend its budget preparing and preflighting every selected
  provider — outside the sealed preparation, catalog, and session binding
  `acquire/6` checks — and only be refused when it reached credential
  resolution.

  `artifact_preflight` is called with the derived effective class, after
  preparation and before any provider is preflighted, because an embedding owns
  the artifact destinations its own build is about to write.
  """
  @spec acquire_embedded(
          ApplicationPackage.t(),
          ProviderRegistry.t(),
          ProviderSession.t(),
          input_class(),
          artifact_preflight()
        ) :: result()
  def acquire_embedded(
        %ApplicationPackage{} = package,
        %ProviderRegistry{} = registry,
        session,
        input_class,
        artifact_preflight
      )
      when input_class in [:normal, :private_inspection] and
             is_function(artifact_preflight, 1) do
    max_heap_words = package.limits.provider_heap_words

    with :ok <- unbounded_session(session),
         {:ok, preparations} <-
           prepare_providers(package, registry, session, max_heap_words, :all),
         :ok <- validate_provider_dependencies(preparations),
         :ok <- validate_workflow_llm_defaults(preparations),
         effective_class <- effective_data_class(input_class, preparations),
         :ok <- providers_accept(preparations, effective_class),
         :ok <- artifact_preflight.(effective_class) do
      complete_acquisition(
        preparations,
        registry,
        session,
        effective_class,
        max_heap_words,
        nil
      )
    end
  end

  def acquire_embedded(_package, _registry, _session, _input_class, _artifact_preflight),
    do: {:error, :invalid_provider_acquisition}

  # The answer is a pure read of the caller's sealed handle, so it cannot change
  # while this acquisition runs: asking it once up front is the same answer
  # credential resolution used to reach after every callback had already run.
  # An unusable handle fails here too, rather than at the first scope it opens.
  defp unbounded_session(session) do
    case ProviderSession.execution_deadline(session) do
      {:ok, nil} -> :ok
      _bounded_or_invalid -> {:error, :invalid_provider_acquisition}
    end
  end

  # The plan decides which provider callbacks run, so the evidence it is
  # projected from is checked before any of them do rather than trusted because
  # a caller supplied it. Alias names are not identity: the preparation and the
  # catalog must be the pair phase 5 validated together, and the session must be
  # the one opened for that preparation. Without the last check a preparation
  # and catalog legitimately sealed for another operation — a different
  # dependency graph over the same application digest, say — would steer this
  # operation's closure and spend its budget and scopes.
  #
  # The caller checks these too; this boundary does not depend on that, because
  # the step that decides which executable code runs has no reason to trust its
  # caller.
  defp bound(prepared, catalog, session) do
    if PreparedRun.active_valid?(prepared) and InstallationCatalog.valid?(catalog) and
         prepared.catalog_attestation == catalog.attestation and
         ProviderSession.bound_to_operation?(session, prepared.attestation) and
         ProviderSession.compatible_limits?(session, prepared.request.package.limits),
       do: :ok,
       else: {:error, :invalid_provider_acquisition}
  end

  # Everything here is read from sealed values: no descriptor is consulted for a
  # name the preparation did not declare, and no callback is invoked.
  defp sealed_occurrences(prepared, catalog) do
    occurrences =
      Enum.map(prepared.provider_declarations, fn declaration ->
        descriptor = Map.fetch!(catalog.descriptors, declaration.name)

        %{
          name: declaration.name,
          destination: declaration.destination,
          index: declaration.index,
          requires: descriptor.requires,
          provides: descriptor.provides,
          credential_names: descriptor.credential_names,
          workflow_llm?: descriptor.workflow_llm?,
          workflow_llm_route:
            workflow_llm_route(
              descriptor.workflow_llm?,
              descriptor.source,
              descriptor.installation_revision,
              declaration.config
            ),
          data_class: descriptor.data_class,
          accepts_data: descriptor.accepts_data
        }
      end)

    {:ok, occurrences}
  rescue
    _exception -> {:error, :invalid_provider_acquisition}
  end

  # A run targets the whole selection, so the closure is every sealed
  # occurrence. An application that reaches acquisition with none is refused
  # rather than succeeding with nothing acquired, exactly as an empty target
  # list is.
  defp sealed_closure([], :all), do: {:error, :invalid_provider_acquisition}
  defp sealed_closure(occurrences, :all), do: {:ok, occurrences}

  # The closure comes from sealed `requires`/`provides` alone, so it is decided
  # before any builder runs. Phase 5 already proved the graph is satisfiable and
  # acyclic over these same values, which is why following it to a fixed point
  # terminates and cannot silently drop a requirement.
  defp sealed_closure(occurrences, targets) do
    by_site = Map.new(occurrences, &{{&1.destination, &1.index}, &1})

    if targets != [] and Enum.all?(targets, &Map.has_key?(by_site, site(&1))) do
      providers_by_service =
        Enum.reduce(occurrences, %{}, fn occurrence, accumulated ->
          Enum.reduce(occurrence.provides, accumulated, &Map.put(&2, &1, site(occurrence)))
        end)

      sites = close_over(MapSet.new(targets, &site/1), by_site, providers_by_service)
      {:ok, Enum.filter(occurrences, &MapSet.member?(sites, site(&1)))}
    else
      {:error, :invalid_provider_acquisition}
    end
  end

  defp site(%{destination: destination, index: index}), do: {destination, index}

  defp close_over(selected, by_site, providers_by_service) do
    added =
      selected
      |> Enum.flat_map(fn site -> Map.fetch!(by_site, site).requires end)
      |> Enum.map(&Map.get(providers_by_service, &1))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    next = MapSet.union(selected, added)

    if MapSet.equal?(next, selected),
      do: selected,
      else: close_over(next, by_site, providers_by_service)
  end

  # Runtime binding checks the data policy only, so the rest of a preparation
  # could contradict the declaration this operation planned from. Inside the
  # closure that is detectable and must fail: adopting the callback's version
  # would let it widen its own dependencies, credentials, or class after the
  # plan was fixed. Credentials are the sharpest case — a preparation that
  # reported a name a *different* selected provider declared would be inside the
  # resolved union and would be served that provider's value — so this runs
  # before preflight, and long before the map is consulted.
  defp declarations_honored(preparations, closure, session) do
    declared = Map.new(closure, &{site(&1), &1})

    case Enum.find(preparations, &(not honors_declaration?(&1, Map.get(declared, site(&1))))) do
      nil -> :ok
      drifting -> callback_error(:provider_declaration_mismatch, drifting, session)
    end
  end

  defp honors_declaration?(_provider, nil), do: false

  defp honors_declaration?(provider, declaration) do
    provider.provider == declaration.name and
      Enum.sort(provider.credential_names) == Enum.sort(declaration.credential_names) and
      Enum.sort(provider.requires) == Enum.sort(declaration.requires) and
      Enum.sort(provider.provides) == Enum.sort(declaration.provides) and
      provider.workflow_llm? == declaration.workflow_llm? and
      provider.workflow_llm_route == declaration.workflow_llm_route and
      provider.data_class == declaration.data_class and
      Enum.sort(provider.accepts_data) == Enum.sort(declaration.accepts_data)
  end

  defp complete_acquisition(
         preparations,
         registry,
         session,
         effective_class,
         max_heap_words,
         credentials
       ) do
    with :ok <- credentials_honored(credentials, preparations, session),
         {:ok, preflighted} <- preflight_providers(preparations, session, max_heap_words) do
      try do
        with {:ok, resolved} <- provider_credentials(credentials, registry, preflighted),
             {:ok, acquired} <-
               acquire_providers(
                 preflighted,
                 resolved,
                 effective_class,
                 session,
                 max_heap_words
               ) do
          acquisition_result(acquired, session)
        end
      after
        ProviderCallbackBoundary.release_preflights(preflighted, session, max_heap_words)
      end
    end
  end

  defp acquisition_result(acquired, session) do
    with {:ok, workflow} <- finalize_capabilities(acquired.workflow, :workflow),
         {:ok, mission} <- finalize_capabilities(acquired.mission, :mission) do
      {:ok,
       acquired
       |> Map.put(:workflow, workflow)
       |> Map.put(:mission, mission)
       |> Map.put(:snapshots, sort_snapshots(acquired.snapshots))
       |> Map.put(:provider_session, session)
       |> Map.delete(:exports)}
    end
  end

  defp sort_snapshots(snapshots), do: Enum.sort_by(snapshots, &Map.get(&1, "provider", ""))

  defp prepare_providers(package, registry, session, max_heap_words, closure) do
    package
    |> provider_specs()
    |> selected_specs(closure)
    |> Enum.reduce_while({:ok, []}, fn {{destination, spec}, index}, {:ok, preparations} ->
      case ProviderSession.open_registrar(session) do
        {:ok, registrar} ->
          prepare_provider(
            package,
            registry,
            session,
            registrar,
            {destination, spec, index},
            preparations,
            max_heap_words
          )

        # Past the operation deadline the session refuses to open a scope. That
        # is the run budget running out rather than a session defect, so it
        # keeps the operation-class diagnostic instead of a bare reason.
        {:error, _reason} ->
          {:halt, {:error, setup_reason(session, :provider_session_unavailable)}}
      end
    end)
    |> reverse_success()
  end

  defp prepare_provider(
         package,
         registry,
         session,
         registrar,
         {destination, spec, index},
         preparations,
         max_heap_words
       ) do
    context =
      session
      |> ProviderCallbackBoundary.context()
      |> Map.merge(%{
        application_content_digest: package.application_content_digest,
        destination: destination,
        owner: ResourceRegistrar.owner(registrar),
        resource_registrar: registrar,
        limits: package.limits,
        installed_limits: package.installed_limits
      })

    callback = fn ->
      ProviderRegistry.prepare(
        registry,
        spec["name"],
        Map.get(spec, "config", %{}),
        context
      )
    end

    occurrence = %{provider: spec["name"], destination: destination, index: index}

    case ProviderCallbackBoundary.invoke(session, max_heap_words, occurrence, callback) do
      {:ok, {:ok, provider}} ->
        entry = %{
          index: index,
          provider: spec["name"],
          destination: destination,
          credential_names: provider.credential_names,
          data_class: provider.data_class,
          accepts_data: provider.accepts_data,
          requires: provider.requires,
          provides: provider.provides,
          workflow_llm?: provider.workflow_llm?,
          workflow_llm_route: provider.workflow_llm_route,
          registrar: registrar,
          prepared: provider
        }

        {:cont, {:ok, [entry | preparations]}}

      {:ok, {:error, reason}} ->
        _ = ResourceRegistrar.abort(registrar)
        {:halt, callback_error(reason, occurrence, session)}

      {:deadline_expired, _callback_result, %CommandDiagnostic{} = diagnostic} ->
        _ = ResourceRegistrar.abort(registrar)
        {:halt, {:error, diagnostic}}

      {:error, %CommandDiagnostic{}} = error ->
        _ = ResourceRegistrar.abort(registrar)
        {:halt, error}
    end
  end

  defp preflight_providers(preparations, session, max_heap_words) do
    preparations
    |> Enum.reduce_while({:ok, []}, fn provider, {:ok, preflighted} ->
      result =
        ProviderCallbackBoundary.invoke(session, max_heap_words, provider, fn ->
          ProviderRegistry.preflight(provider.prepared)
        end)

      case result do
        {:ok, {:ok, phase}} ->
          entry =
            provider
            |> Map.delete(:prepared)
            |> Map.put(:preflighted, phase)

          {:cont, {:ok, [entry | preflighted]}}

        {:ok, {:error, reason}} ->
          ProviderCallbackBoundary.release_preflights(preflighted, session, max_heap_words)
          {:halt, callback_error(reason, provider, session)}

        {:deadline_expired, callback_result, %CommandDiagnostic{} = diagnostic} ->
          release_expired_preflight(callback_result, preflighted, session, max_heap_words)
          {:halt, {:error, diagnostic}}

        {:error, %CommandDiagnostic{}} = error ->
          ProviderCallbackBoundary.release_preflights(preflighted, session, max_heap_words)
          {:halt, error}
      end
    end)
    |> reverse_success()
  end

  defp acquire_providers(
         preflighted,
         credentials,
         effective_class,
         session,
         max_heap_words
       ) do
    initial = %{
      workflow: %{capabilities: []},
      mission: %{capabilities: []},
      snapshots: [],
      exports: %{},
      data_class: effective_class
    }

    acquire_ready_providers(preflighted, credentials, initial, session, max_heap_words)
  end

  defp acquire_ready_providers([], _credentials, accumulated, _session, _max_heap_words),
    do: {:ok, accumulated}

  defp acquire_ready_providers(pending, credentials, accumulated, session, max_heap_words) do
    case Enum.split_with(pending, &services_available?(&1, accumulated.exports)) do
      {[], _blocked} ->
        {:error, :provider_dependency_unavailable}

      {ready, blocked} ->
        case acquire_provider_batch(ready, credentials, accumulated, session, max_heap_words) do
          {:ok, next} ->
            acquire_ready_providers(blocked, credentials, next, session, max_heap_words)

          {:unregistered_provider_close, _reason, _close} = cleanup ->
            cleanup

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp acquire_provider_batch(providers, credentials, accumulated, session, max_heap_words) do
    Enum.reduce_while(providers, {:ok, accumulated}, fn provider, {:ok, current} ->
      provider_credentials = Map.take(credentials, provider.credential_names)
      services = selected_services(current.exports, provider.requires)

      result =
        acquire_provider(provider, provider_credentials, services, session, max_heap_words)

      handle_acquisition(result, provider, session, current)
    end)
  end

  defp acquire_provider(provider, credentials, services, session, max_heap_words) do
    with :ok <- activate_for_acquisition(provider, session) do
      case ProviderCallbackBoundary.invoke(session, max_heap_words, provider, fn ->
             ProviderRegistry.acquire_unreleased(provider.preflighted, credentials, services)
           end) do
        {:ok, callback_result} ->
          callback_result

        {:deadline_expired, callback_result, diagnostic} ->
          preserve_expired_acquisition(provider, callback_result, diagnostic)

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Activation is bounded by the operation deadline now, so its failure can mean
  # the budget ran out rather than the scope being unusable.
  defp activate_for_acquisition(provider, session) do
    case ResourceRegistrar.activate(provider.registrar) do
      :ok -> :ok
      {:error, reason} -> {:error, setup_reason(session, reason)}
    end
  end

  defp handle_acquisition({:ok, built}, provider, _session, current)
       when built.data_class == provider.data_class and
              built.accepts_data == provider.accepts_data do
    case ResourceRegistrar.commit(provider.registrar, built.close) do
      :ok ->
        environment = Map.fetch!(current, provider.destination)

        next =
          current
          |> Map.put(provider.destination, %{
            capabilities: [
              %{
                index: provider.index,
                provider: provider.provider,
                workflow_llm?: provider.workflow_llm?,
                workflow_llm_route: provider.workflow_llm_route,
                capabilities: built.capabilities
              }
              | environment.capabilities
            ]
          })
          |> Map.update!(:snapshots, &maybe_append(&1, built.snapshot))
          |> Map.update!(:exports, &merge_provider_exports(&1, provider.provider, built.exports))

        {:cont, {:ok, next}}

      # The session took ownership and then became unreachable without running
      # the closer. It is the only owner this closer ever had, so re-running it
      # here would be a second run of work that may already have happened. The
      # reason is minted here rather than reported by a provider, so it carries
      # its catalogued code instead of a bare atom a consumer would collapse.
      {:error, :provider_cleanup_failed} ->
        {:halt, {:error, unreleased_diagnostic()}}

      {:error, _reason} ->
        {:halt, {:unregistered_provider_close, :provider_session_unavailable, built.close}}
    end
  end

  defp handle_acquisition({:ok, built}, provider, session, _current) do
    case ResourceRegistrar.commit(provider.registrar, built.close) do
      :ok ->
        {:halt, callback_error(:provider_data_policy_changed, provider, session)}

      {:error, :provider_cleanup_failed} ->
        {:halt, {:error, unreleased_diagnostic()}}

      {:error, _reason} ->
        {:halt, {:unregistered_provider_close, :provider_data_policy_changed, built.close}}
    end
  end

  defp handle_acquisition(
         {:unregistered_provider_close, _reason, _close} = cleanup,
         _provider,
         _session,
         _current
       ),
       do: {:halt, cleanup}

  # A diagnostic already carries its occurrence; only a bare reason from the
  # acquire callback still needs one attached.
  defp handle_acquisition({:error, %CommandDiagnostic{}} = error, provider, _session, _current) do
    _ = ResourceRegistrar.abort(provider.registrar)
    {:halt, error}
  end

  defp handle_acquisition({:error, reason}, provider, session, _current) do
    _ = ResourceRegistrar.abort(provider.registrar)
    {:halt, callback_error(reason, provider, session)}
  end

  # An active command must classify here, because a `provider_acquisition` code
  # requires a subject bearing an occurrence and this is the last frame that
  # knows which occurrence produced the reason. Direct embedding keeps the bare
  # reason: it has no envelope to render a diagnostic into, and the raw
  # vocabulary is far richer than three closed codes can express.
  defp callback_error(reason, occurrence, session) do
    case ProviderSession.execution_deadline(session) do
      {:ok, nil} -> {:error, reason}
      {:ok, _deadline} -> {:error, AcquisitionReason.diagnostic(reason, occurrence)}
      :error -> {:error, reason}
    end
  end

  defp services_available?(provider, exports),
    do: Enum.all?(provider.requires, &match?([{_provider, _value}], Map.get(exports, &1)))

  defp merge_provider_exports(exports, provider, built_exports) do
    Enum.reduce(built_exports, exports, fn {service, value}, accumulated ->
      Map.update(accumulated, service, [{provider, value}], &[{provider, value} | &1])
    end)
  end

  defp selected_services(exports, requires) do
    Map.new(requires, fn service ->
      [{_provider, value}] = Map.fetch!(exports, service)
      {service, value}
    end)
  end

  defp finalize_capabilities(%{capabilities: entries}, :mission) do
    if Enum.any?(entries, & &1.workflow_llm?) do
      {:error, :invalid_workflow_llm_provider}
    else
      {:ok,
       %{
         capabilities: flatten_capability_entries(entries),
         by_occurrence:
           entries
           |> Enum.sort_by(& &1.index)
           |> Map.new(&{&1.index, &1.capabilities})
       }}
    end
  end

  defp finalize_capabilities(%{capabilities: entries}, :workflow) do
    {llm_entries, ordinary_entries} = Enum.split_with(entries, & &1.workflow_llm?)

    if llm_entries == [] do
      {:ok, %{capabilities: flatten_capability_entries(ordinary_entries)}}
    else
      with :ok <- no_unclaimed_llm_request(ordinary_entries),
           {:ok, router_entry} <- build_llm_router_entry(llm_entries) do
        {:ok, %{capabilities: flatten_capability_entries([router_entry | ordinary_entries])}}
      end
    end
  end

  defp flatten_capability_entries(entries) do
    entries
    |> Enum.sort_by(& &1.index)
    |> Enum.flat_map(& &1.capabilities)
  end

  defp no_unclaimed_llm_request(entries) do
    if Enum.any?(entries, fn entry ->
         Enum.any?(entry.capabilities, &(&1.name == "llm-request"))
       end),
       do: {:error, :invalid_workflow_llm_provider},
       else: :ok
  end

  defp build_llm_router_entry(entries) do
    with true <- Enum.all?(entries, &match?([%{name: "llm-request"}], &1.capabilities)),
         routes <- Enum.map(entries, &llm_route/1),
         {:ok, router} <- LLMRouter.new(routes) do
      {:ok,
       %{
         index: Enum.min_by(entries, & &1.index).index,
         provider: "llm-router",
         workflow_llm?: false,
         workflow_llm_route: nil,
         capabilities: [router]
       }}
    else
      _invalid -> {:error, :invalid_workflow_llm_provider}
    end
  end

  defp llm_route(entry) do
    %{
      alias: entry.provider,
      source: entry.workflow_llm_route.source,
      installation_revision: entry.workflow_llm_route.installation_revision,
      default?: entry.workflow_llm_route.default,
      capability: List.first(entry.capabilities)
    }
  end

  defp validate_provider_dependencies(preparations) do
    provided = Enum.flat_map(preparations, & &1.provides)
    required = Enum.flat_map(preparations, & &1.requires) |> Enum.uniq()
    counts = Enum.frequencies(provided)

    cond do
      Enum.any?(required, &(Map.get(counts, &1, 0) == 0)) ->
        {:error, :provider_dependency_unavailable}

      Enum.any?(required, &(Map.fetch!(counts, &1) > 1)) ->
        {:error, :ambiguous_provider_dependency}

      true ->
        :ok
    end
  end

  defp validate_workflow_llm_defaults(preparations) do
    workflow_llms =
      Enum.filter(preparations, fn entry ->
        entry.destination == :workflow and entry.workflow_llm?
      end)

    defaults = Enum.count(workflow_llms, & &1.workflow_llm_route.default)

    if defaults > 1, do: {:error, :ambiguous_workflow_llm_default}, else: :ok
  end

  defp workflow_llm_route(false, _source, _revision, _config), do: nil

  defp workflow_llm_route(true, source, revision, config) do
    %{
      source: Atom.to_string(source),
      installation_revision: revision,
      default: Map.get(config, "default", false)
    }
  end

  # Occurrence identity is `{destination, index}` with the index restarting per
  # destination, which is what the sealed declarations and `ConnectivityResult`
  # use. A single global counter would have named a mission occurrence by a
  # number no other boundary agrees with.
  defp provider_specs(package) do
    for destination <- [:workflow, :mission],
        {spec, index} <- Enum.with_index(Map.fetch!(package.providers, destination)),
        do: {{destination, spec}, index}
  end

  defp selected_specs(specs, :all), do: specs

  # A closure site with no matching spec cannot arise: the preparation's seal
  # pins its declarations to `package.providers` by `{destination, index, name}`,
  # and `bound/3` verified that seal before this ran.
  defp selected_specs(specs, closure) do
    sites = MapSet.new(closure, &site/1)

    Enum.filter(specs, fn {{destination, _spec}, index} ->
      MapSet.member?(sites, {destination, index})
    end)
  end

  defp credential_names(preflighted) do
    preflighted
    |> Enum.flat_map(& &1.credential_names)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A supplied map is the active command's phase-8 step-5 result, resolved from
  # the sealed declarations of the whole selection. `declarations_honored/3`
  # has already proved each preparation reports exactly its own declaration, so
  # what remains to check is the map itself: a resolution that does not cover a
  # declared name would otherwise hand a provider fewer credentials than it
  # declared, silently, at `Map.take/2`. An embedding supplies no map and
  # resolves below instead.
  defp credentials_honored(nil, _preparations, _session), do: :ok

  defp credentials_honored(credentials, preparations, session) do
    covered = MapSet.new(Map.keys(credentials))

    case Enum.find(preparations, &(not MapSet.subset?(MapSet.new(&1.credential_names), covered))) do
      nil -> :ok
      drifting -> callback_error(:provider_declaration_mismatch, drifting, session)
    end
  end

  defp provider_credentials(credentials, _registry, _preflighted)
       when is_map(credentials),
       do: {:ok, credentials}

  # Direct embedding: no sealed declarations to derive a union from before
  # preparation, and no operation deadline to bound it, so the registry's
  # synchronous resolution stays its documented contract. Only
  # `acquire_embedded/5` reaches this clause, and it proved the session is an
  # embedding one before the first callback rather than here, after the last.
  defp provider_credentials(nil, registry, preflighted),
    do: ProviderRegistry.resolve_credentials(registry, credential_names(preflighted))

  # An expired operation deadline during scope setup is that operation's own
  # timeout, and the operations do not share a code: the connect contract
  # admits no execution-phase diagnostic at all, so reporting a run timeout
  # there would fail outcome construction rather than describe the failure.
  defp setup_reason(session, fallback) do
    case ProviderSession.execution_deadline(session) do
      {:ok, deadline} when not is_nil(deadline) ->
        if Deadline.expired?(deadline),
          do: setup_timeout_diagnostic(ProviderSession.begun_operation(session)),
          else: fallback

      _other ->
        fallback
    end
  end

  defp setup_timeout_diagnostic(:connect),
    do: CommandDiagnostic.new!(:active_preflight, :connectivity_timeout, provider_activity: true)

  defp setup_timeout_diagnostic(_operation), do: run_timeout_diagnostic()

  defp run_timeout_diagnostic,
    do: CommandDiagnostic.new!(:execution, :run_timeout, provider_activity: true)

  defp reverse_success({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_success({:error, _reason} = error), do: error

  # The deadline that produced `{:deadline_expired, ...}` is the one the session
  # fences commit with, and it never re-anchors, so in practice the commit below
  # is always refused and the closer always leaves with its caller. The other
  # two clauses are kept because they are the correct answers if a commit does
  # land — the reported diagnostic is the same either way, only the owner of the
  # closer differs.
  defp preserve_expired_acquisition(provider, {:ok, built}, diagnostic) do
    case ResourceRegistrar.commit(provider.registrar, built.close) do
      :ok -> {:error, diagnostic}
      # The cleanup failure is the newer fact and outranks the expiry that
      # preceded it, matching what `handle_acquisition/3` does with the same
      # answer. Reporting the expiry here would lose the unreleased resource.
      {:error, :provider_cleanup_failed} -> {:error, unreleased_diagnostic()}
      {:error, _reason} -> {:unregistered_provider_close, diagnostic, built.close}
    end
  end

  defp preserve_expired_acquisition(_provider, _callback_result, diagnostic),
    do: {:error, diagnostic}

  defp unreleased_diagnostic,
    do: CommandDiagnostic.new!(:result_cleanup, :provider_cleanup_failed, provider_activity: true)

  defp release_expired_preflight({:ok, phase}, preflighted, session, max_heap_words),
    do:
      ProviderCallbackBoundary.release_preflights(
        [phase | preflighted],
        session,
        max_heap_words
      )

  defp release_expired_preflight(_callback_result, preflighted, session, max_heap_words),
    do: ProviderCallbackBoundary.release_preflights(preflighted, session, max_heap_words)

  defp strictest_data_class(:private_inspection, _next), do: :private_inspection
  defp strictest_data_class(_current, :private_inspection), do: :private_inspection
  defp strictest_data_class(:normal, :normal), do: :normal

  defp effective_data_class(input_class, preparations) do
    Enum.reduce(preparations, input_class, fn provider, current ->
      strictest_data_class(current, provider.data_class)
    end)
  end

  defp providers_accept(preparations, effective_class) do
    if Enum.all?(preparations, &(effective_class in &1.accepts_data)),
      do: :ok,
      else: {:error, :provider_data_class_denied}
  end

  defp maybe_append(values, nil), do: values
  defp maybe_append(values, value), do: values ++ [value]
end
