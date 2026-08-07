defmodule PtcRunner.Kernel.ProviderAcquisition do
  @moduledoc """
  Acquires one prepared run's selected providers through its active session.

  The acquisition barrier prepares every selected provider, validates service
  dependencies and information-flow policy, completes local preflight, resolves
  the credential union once, and then acquires providers in dependency order.
  Each acquired provider is committed to its provisional registrar immediately,
  before the next provider can run.

  For an active command, provider preparation, preflight, acquisition, and
  credential resolution run in owner-linked bounded work using the remaining
  shared run deadline and provider heap limit. Preflight releases use one
  shared provider-cleanup budget. A direct embedding session without an
  operation deadline retains the registry's synchronous callback semantics.

  `acquire_subset/6` narrows which providers are acquired without narrowing any
  judgement about the application: see its documentation for what stays
  whole-application and why. An ordinary run and check acquire `:all`, which is
  the same path this module always took.

  This module does not own the provider session. Its caller closes that session
  after any error and retains it with a successful acquisition result.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderCallbackBoundary
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar

  @type input_class :: :normal | :private_inspection
  @type artifact_preflight :: (input_class() -> :ok | {:error, term()})
  @type occurrence :: %{destination: :workflow | :mission, index: non_neg_integer()}
  @type plan :: %{
          effective_class: input_class(),
          occurrences: [map()],
          package_digest: binary()
        }

  @doc false
  @spec acquire(
          ApplicationPackage.t(),
          ProviderRegistry.t(),
          ProviderSession.t(),
          input_class(),
          artifact_preflight()
        ) ::
          {:ok, map()}
          | {:error, term()}
          | {:unregistered_provider_close, term(), ProviderRegistry.close()}
  def acquire(
        %ApplicationPackage{} = package,
        %ProviderRegistry{} = registry,
        session,
        input_class,
        artifact_preflight
      )
      when input_class in [:normal, :private_inspection] and
             is_function(artifact_preflight, 1) do
    max_heap_words = package.limits.provider_heap_words

    with {:ok, prepared} <-
           prepare_providers(package, registry, session, max_heap_words, :all),
         :ok <- validate_provider_dependencies(prepared),
         :ok <- validate_single_workflow_llm(prepared),
         effective_class <- effective_data_class(input_class, prepared),
         :ok <- providers_accept(prepared, effective_class),
         :ok <- artifact_preflight.(effective_class) do
      complete_acquisition(prepared, registry, session, effective_class, max_heap_words)
    end
  end

  def acquire(_package, _registry, _session, _input_class, _artifact_preflight),
    do: {:error, :invalid_provider_acquisition}

  @doc """
  Acquires the sealed acquisition targets of one prepared run, and nothing else.

  This is the connectivity entry. Its contract is that a provider the sealed
  declarations did not name — directly or as a dependency — stays completely
  callback-inert: not prepared, not preflighted, not asked for credentials, not
  acquired. Preparation is provider work, not a lookup. A prepare callback can
  fail the whole operation, block until the deadline, spend the budget a real
  target needed, and register provisional roots that outlive it, so "prepare
  everything and then narrow" narrows nothing that matters.

  `plan` is therefore sealed evidence rather than discovered evidence. It comes
  from `plan/2` over a `PreparedRun` and the exact catalog it was validated
  against, and it supplies both halves this operation needs without invoking
  anything: the dependency graph that decides the closure, and the
  whole-application judgements phase 5 already made. Deriving the closure from
  callback-reported `requires`/`provides` instead would make the authority to
  invoke a callback depend on invoking callbacks, and would let executable code
  redirect which executable code runs.

  Targets are `{destination, index}` occurrences, the same identity the sealed
  declarations and `ConnectivityResult` use. They are checked against the plan
  before any callback runs, so an unknown or empty target set costs nothing.

  Inside the closure, each preparation is compared with its sealed declaration
  and drift fails closed. Dependency-only providers are support work: acquired
  and cleaned up like any other, and never reported as a caller's own result.
  """
  @spec acquire_targets(
          ApplicationPackage.t(),
          ProviderRegistry.t(),
          ProviderSession.t(),
          [occurrence()],
          artifact_preflight(),
          plan()
        ) ::
          {:ok, map()}
          | {:error, term()}
          | {:unregistered_provider_close, term(), ProviderRegistry.close()}
  def acquire_targets(
        %ApplicationPackage{} = package,
        %ProviderRegistry{} = registry,
        session,
        targets,
        artifact_preflight,
        %{effective_class: effective_class, occurrences: occurrences} = plan
      )
      when is_list(targets) and is_function(artifact_preflight, 1) do
    max_heap_words = package.limits.provider_heap_words

    with :ok <- validate_plan(plan, package),
         {:ok, closure} <- sealed_closure(occurrences, targets),
         :ok <- artifact_preflight.(effective_class),
         {:ok, prepared} <-
           prepare_providers(package, registry, session, max_heap_words, closure),
         :ok <- declarations_honored(prepared, closure) do
      complete_acquisition(
        prepared,
        registry,
        session,
        effective_class,
        max_heap_words
      )
    end
  end

  def acquire_targets(
        _package,
        _registry,
        _session,
        _targets,
        _artifact_preflight,
        _plan
      ),
      do: {:error, :invalid_provider_acquisition}

  @doc """
  Projects the sealed acquisition plan of one prepared run against its catalog.

  Alias names are not identity, so the preparation and the catalog must be the
  pair phase 5 validated together. Everything here is read from sealed values:
  no descriptor is consulted for a name the preparation did not declare, and no
  callback is invoked.
  """
  @spec plan(PreparedRun.t(), InstallationCatalog.t()) ::
          {:ok, plan()} | {:error, :invalid_provider_acquisition}
  def plan(%PreparedRun{} = prepared, %InstallationCatalog{} = catalog) do
    if prepared.catalog_attestation == catalog.attestation and
         InstallationCatalog.valid?(catalog) do
      occurrences =
        Enum.map(prepared.provider_declarations, fn declaration ->
          descriptor = Map.fetch!(catalog.descriptors, declaration.name)

          %{
            name: declaration.name,
            destination: declaration.destination,
            index: declaration.index,
            config: declaration.config,
            requires: descriptor.requires,
            provides: descriptor.provides,
            credential_names: descriptor.credential_names,
            workflow_llm?: descriptor.workflow_llm?,
            data_class: descriptor.data_class,
            accepts_data: descriptor.accepts_data
          }
        end)

      {:ok,
       %{
         effective_class: prepared.effective_data_class,
         occurrences: occurrences,
         package_digest: prepared.request.package.application_content_digest
       }}
    else
      {:error, :invalid_provider_acquisition}
    end
  rescue
    _exception -> {:error, :invalid_provider_acquisition}
  end

  def plan(_prepared, _catalog), do: {:error, :invalid_provider_acquisition}

  defp validate_plan(%{package_digest: digest}, package) do
    if digest == package.application_content_digest,
      do: :ok,
      else: {:error, :invalid_provider_acquisition}
  end

  defp validate_plan(_plan, _package), do: {:error, :invalid_provider_acquisition}

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
  # plan was fixed.
  defp declarations_honored(prepared, closure) do
    declared = Map.new(closure, &{site(&1), &1})

    if Enum.all?(prepared, &honors_declaration?(&1, Map.get(declared, site(&1)))),
      do: :ok,
      else: {:error, :provider_declaration_mismatch}
  end

  defp honors_declaration?(_provider, nil), do: false

  defp honors_declaration?(provider, declaration) do
    provider.provider == declaration.name and
      Enum.sort(provider.credential_names) == Enum.sort(declaration.credential_names) and
      Enum.sort(provider.requires) == Enum.sort(declaration.requires) and
      Enum.sort(provider.provides) == Enum.sort(declaration.provides) and
      provider.workflow_llm? == declaration.workflow_llm? and
      provider.data_class == declaration.data_class and
      Enum.sort(provider.accepts_data) == Enum.sort(declaration.accepts_data)
  end

  defp complete_acquisition(prepared, registry, session, effective_class, max_heap_words) do
    with {:ok, preflighted} <- preflight_providers(prepared, session, max_heap_words) do
      try do
        with {:ok, credentials} <-
               resolve_provider_credentials(registry, preflighted, session, max_heap_words),
             {:ok, acquired} <-
               acquire_providers(
                 preflighted,
                 credentials,
                 effective_class,
                 session,
                 max_heap_words
               ) do
          {:ok, acquisition_result(acquired, session)}
        end
      after
        ProviderCallbackBoundary.release_preflights(preflighted, session, max_heap_words)
      end
    end
  end

  defp acquisition_result(acquired, session) do
    acquired
    |> Map.put(:workflow, finalize_capabilities(acquired.workflow))
    |> Map.put(:mission, finalize_capabilities(acquired.mission))
    |> Map.put(:snapshots, sort_snapshots(acquired.snapshots))
    |> Map.put(:provider_session, session)
    |> Map.delete(:exports)
  end

  defp sort_snapshots(snapshots), do: Enum.sort_by(snapshots, &Map.get(&1, "provider", ""))

  defp prepare_providers(package, registry, session, max_heap_words, closure) do
    package
    |> provider_specs()
    |> selected_specs(closure)
    |> Enum.reduce_while({:ok, []}, fn {{destination, spec}, index}, {:ok, prepared} ->
      case ProviderSession.open_registrar(session) do
        {:ok, registrar} ->
          prepare_provider(
            package,
            registry,
            session,
            registrar,
            {destination, spec, index},
            prepared,
            max_heap_words
          )

        # Past the operation deadline the session refuses to open a scope. That
        # is the run budget running out rather than a session defect, so it
        # keeps the operation-class diagnostic instead of a bare reason.
        {:error, _reason} ->
          {:halt, {:error, prepare_setup_reason(session)}}
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
         prepared,
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
          registrar: registrar,
          prepared: provider
        }

        {:cont, {:ok, [entry | prepared]}}

      {:ok, {:error, _reason} = error} ->
        _ = ResourceRegistrar.abort(registrar)
        {:halt, error}

      {:deadline_expired, _callback_result, %CommandDiagnostic{} = diagnostic} ->
        _ = ResourceRegistrar.abort(registrar)
        {:halt, {:error, diagnostic}}

      {:error, %CommandDiagnostic{}} = error ->
        _ = ResourceRegistrar.abort(registrar)
        {:halt, error}
    end
  end

  defp preflight_providers(prepared, session, max_heap_words) do
    prepared
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

        {:ok, {:error, _reason} = error} ->
          ProviderCallbackBoundary.release_preflights(preflighted, session, max_heap_words)
          {:halt, error}

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

      handle_acquisition(result, provider, current)
    end)
  end

  defp acquire_provider(provider, credentials, services, session, max_heap_words) do
    with :ok <- ResourceRegistrar.activate(provider.registrar) do
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

  defp handle_acquisition({:ok, built}, provider, current)
       when built.data_class == provider.data_class and
              built.accepts_data == provider.accepts_data do
    case ResourceRegistrar.commit(provider.registrar, built.close) do
      :ok ->
        environment = Map.fetch!(current, provider.destination)

        next =
          current
          |> Map.put(provider.destination, %{
            capabilities: [{provider.index, built.capabilities} | environment.capabilities]
          })
          |> Map.update!(:snapshots, &maybe_append(&1, built.snapshot))
          |> Map.update!(:exports, &merge_provider_exports(&1, provider.provider, built.exports))

        {:cont, {:ok, next}}

      {:error, _reason} ->
        {:halt, {:unregistered_provider_close, :provider_session_unavailable, built.close}}
    end
  end

  defp handle_acquisition({:ok, built}, provider, _current) do
    case ResourceRegistrar.commit(provider.registrar, built.close) do
      :ok ->
        {:halt, {:error, :provider_data_policy_changed}}

      {:error, _reason} ->
        {:halt, {:unregistered_provider_close, :provider_data_policy_changed, built.close}}
    end
  end

  defp handle_acquisition(
         {:unregistered_provider_close, _reason, _close} = cleanup,
         _provider,
         _current
       ),
       do: {:halt, cleanup}

  defp handle_acquisition({:error, _reason} = error, provider, _current) do
    _ = ResourceRegistrar.abort(provider.registrar)
    {:halt, error}
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

  defp finalize_capabilities(%{capabilities: capabilities}) do
    %{
      capabilities:
        capabilities
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.flat_map(&elem(&1, 1))
    }
  end

  defp validate_provider_dependencies(prepared) do
    provided = Enum.flat_map(prepared, & &1.provides)
    required = Enum.flat_map(prepared, & &1.requires) |> Enum.uniq()
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

  # A run has one frozen workflow environment, so it has one language model.
  # Selecting a live alias and a replay alias together would otherwise be
  # decided by whichever capability won the duplicate-name check during
  # environment construction — after fixtures were opened and credentials
  # resolved. An evaluation trial has to be attributable to its configured
  # provider, so this fails while every provider is still inert.
  defp validate_single_workflow_llm(prepared) do
    workflow_llms =
      Enum.count(prepared, fn entry ->
        entry.destination == :workflow and entry.workflow_llm?
      end)

    if workflow_llms > 1, do: {:error, :ambiguous_workflow_llm}, else: :ok
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

  defp selected_specs(specs, closure) do
    sites = MapSet.new(closure, &site/1)

    Enum.filter(specs, fn {{destination, _spec}, index} ->
      MapSet.member?(sites, {destination, index})
    end)
  end

  defp credential_names(prepared) do
    prepared
    |> Enum.flat_map(& &1.credential_names)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp resolve_provider_credentials(registry, providers, session, max_heap_words) do
    names = credential_names(providers)

    case ProviderSession.execution_deadline(session) do
      {:ok, nil} ->
        ProviderRegistry.resolve_credentials(registry, names)

      {:ok, deadline} when names == [] ->
        if Deadline.expired?(deadline),
          do: {:error, run_timeout_diagnostic()},
          else: {:ok, %{}}

      {:ok, deadline} ->
        resolve_active_credentials(registry, names, providers, session, deadline, max_heap_words)

      :error ->
        {:error, :provider_session_unavailable}
    end
  end

  defp resolve_active_credentials(
         registry,
         names,
         providers,
         session,
         deadline,
         max_heap_words
       ) do
    result =
      case Deadline.remaining(deadline) do
        0 ->
          {:error, :timeout}

        timeout_ms ->
          BoundedWorker.run(fn -> ProviderRegistry.resolve_credentials(registry, names) end,
            timeout_ms: timeout_ms,
            max_heap_words: max_heap_words,
            cancel_with_caller: true,
            cancel_with: ProviderSession.worker_cancel_target(session)
          )
      end

    if Deadline.expired?(deadline) do
      {:error, credential_diagnostic(providers)}
    else
      case result do
        {:ok, {:ok, credentials}} -> {:ok, credentials}
        _failure -> {:error, credential_diagnostic(providers)}
      end
    end
  end

  defp credential_diagnostic(providers) do
    provider = Enum.find(providers, hd(providers), &(&1.credential_names != []))
    {:ok, subject} = CommandSubject.provider(provider.provider, :credentials)

    CommandDiagnostic.new!(:active_preflight, :credential_unavailable,
      subject: subject,
      provider_activity: true
    )
  end

  defp prepare_setup_reason(session) do
    case ProviderSession.execution_deadline(session) do
      {:ok, deadline} when not is_nil(deadline) ->
        if Deadline.expired?(deadline),
          do: run_timeout_diagnostic(),
          else: :provider_session_unavailable

      _other ->
        :provider_session_unavailable
    end
  end

  defp run_timeout_diagnostic,
    do: CommandDiagnostic.new!(:execution, :run_timeout, provider_activity: true)

  defp reverse_success({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_success({:error, _reason} = error), do: error

  defp preserve_expired_acquisition(provider, {:ok, built}, diagnostic) do
    case ResourceRegistrar.commit(provider.registrar, built.close) do
      :ok -> {:error, diagnostic}
      {:error, _reason} -> {:unregistered_provider_close, diagnostic, built.close}
    end
  end

  defp preserve_expired_acquisition(_provider, _callback_result, diagnostic),
    do: {:error, diagnostic}

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

  defp effective_data_class(input_class, prepared) do
    Enum.reduce(prepared, input_class, fn provider, current ->
      strictest_data_class(current, provider.data_class)
    end)
  end

  defp providers_accept(prepared, effective_class) do
    if Enum.all?(prepared, &(effective_class in &1.accepts_data)),
      do: :ok,
      else: {:error, :provider_data_class_denied}
  end

  defp maybe_append(values, nil), do: values
  defp maybe_append(values, value), do: values ++ [value]
end
