defmodule PtcRunner.Kernel.ProviderAcquisition do
  @moduledoc """
  Acquires one prepared run's selected providers through its active session.

  The acquisition barrier prepares every selected provider, validates service
  dependencies and information-flow policy, completes local preflight, and then
  acquires providers in dependency order. Each acquired provider is committed to
  its provisional registrar immediately, before the next provider can run.

  Credentials are supplied, not resolved here. An active command resolves them
  once at phase-8 step 5 from its sealed declarations, before any provider
  callback runs, and hands the map down. Each provider then receives only the
  names its own preparation reported, and a preparation reporting a name the
  supplied map does not cover is drift that fails closed.

  That bound is the sealed *union*, not the individual declaration, and the
  difference matters on this path. `acquire_targets/7` additionally requires
  each preparation to report exactly what its sealed declaration says, so a
  target can only ever see its own credential. `acquire/6` has no plan to
  compare against, so a preparation that reports a name belonging to a
  *different* selected provider is still inside the union and still served.
  Closing that needs the ordinary path to carry sealed per-occurrence
  declarations too, which is the `acquire/6`–`acquire_targets/7` unification
  rather than another check here; until then the guarantee this path enforces
  is that no credential outside the selection's own sealed union is ever
  resolved or handed to anything.

  For an active command, provider preparation, preflight, and acquisition run in
  owner-linked bounded work using the remaining shared run deadline and provider
  heap limit. Preflight releases use one shared provider-cleanup budget. A
  direct embedding session without an operation deadline supplies no map and
  retains the registry's synchronous credential and callback semantics.

  `acquire_targets/7` narrows which providers are acquired without narrowing any
  judgement about the application: see its documentation for what stays
  whole-application and why. An ordinary run and check use `acquire/6`, which is
  the same complete path this module always took.

  This module does not own the provider session. Its caller closes that session
  after any error and retains it with a successful acquisition result.
  """

  alias PtcRunner.Kernel.AcquisitionReason
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandDiagnostic
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
  @type credentials :: %{binary() => binary()} | nil
  @type plan :: %{
          effective_class: input_class(),
          occurrences: [map()],
          package_digest: binary(),
          prepared_attestation: binary(),
          catalog_attestation: binary(),
          attestation: binary()
        }

  @doc false
  @spec acquire(
          ApplicationPackage.t(),
          ProviderRegistry.t(),
          ProviderSession.t(),
          input_class(),
          artifact_preflight(),
          credentials()
        ) ::
          {:ok, map()}
          | {:error, term()}
          | {:unregistered_provider_close, term(), ProviderRegistry.close()}
  def acquire(
        %ApplicationPackage{} = package,
        %ProviderRegistry{} = registry,
        session,
        input_class,
        artifact_preflight,
        credentials
      )
      when input_class in [:normal, :private_inspection] and
             is_function(artifact_preflight, 1) and
             (is_nil(credentials) or (is_map(credentials) and not is_struct(credentials))) do
    max_heap_words = package.limits.provider_heap_words

    with {:ok, prepared} <-
           prepare_providers(package, registry, session, max_heap_words, :all),
         :ok <- validate_provider_dependencies(prepared),
         :ok <- validate_single_workflow_llm(prepared),
         effective_class <- effective_data_class(input_class, prepared),
         :ok <- providers_accept(prepared, effective_class),
         :ok <- artifact_preflight.(effective_class) do
      complete_acquisition(
        prepared,
        registry,
        session,
        effective_class,
        max_heap_words,
        credentials
      )
    end
  end

  def acquire(_package, _registry, _session, _input_class, _artifact_preflight, _credentials),
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

  `credentials` is the map phase-8 step 5 resolved for the whole selection. It
  is deliberately wider than this closure: connectivity must answer for every
  selected occurrence, including ones no closure reaches.
  """
  @spec acquire_targets(
          ApplicationPackage.t(),
          ProviderRegistry.t(),
          ProviderSession.t(),
          [occurrence()],
          artifact_preflight(),
          plan(),
          credentials()
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
        %{effective_class: effective_class, occurrences: occurrences} = plan,
        credentials
      )
      when is_list(targets) and is_function(artifact_preflight, 1) and
             (is_nil(credentials) or (is_map(credentials) and not is_struct(credentials))) do
    max_heap_words = package.limits.provider_heap_words

    with :ok <- validate_plan(plan, package),
         {:ok, closure} <- sealed_closure(occurrences, targets),
         :ok <- artifact_preflight.(effective_class),
         {:ok, prepared} <-
           prepare_providers(package, registry, session, max_heap_words, closure),
         :ok <- declarations_honored(prepared, closure, session) do
      complete_acquisition(
        prepared,
        registry,
        session,
        effective_class,
        max_heap_words,
        credentials
      )
    end
  end

  def acquire_targets(
        _package,
        _registry,
        _session,
        _targets,
        _artifact_preflight,
        _plan,
        _credentials
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

      fields = %{
        effective_class: prepared.effective_data_class,
        occurrences: occurrences,
        package_digest: prepared.request.package.application_content_digest,
        prepared_attestation: prepared.attestation,
        catalog_attestation: catalog.attestation
      }

      {:ok, Map.put(fields, :attestation, Attestation.attest(__MODULE__, payload(fields)))}
    else
      {:error, :invalid_provider_acquisition}
    end
  rescue
    _exception -> {:error, :invalid_provider_acquisition}
  end

  def plan(_prepared, _catalog), do: {:error, :invalid_provider_acquisition}

  defp payload(fields),
    do:
      {fields.package_digest, fields.prepared_attestation, fields.catalog_attestation,
       fields.effective_class, fields.occurrences}

  # The plan decides which provider callbacks run, so it is checked before any
  # of them do rather than trusted because its caller built it. Comparing the
  # package digest alone was not enough: an edited `occurrences` list keeps the
  # digest and steers `sealed_closure/2` into preparing providers the selection
  # never reached, and `declarations_honored/3` only notices afterwards — which
  # makes the authority to invoke a callback depend on invoking callbacks, the
  # exact inversion this module's design rejects.
  #
  # The seal covers the preparation and catalog attestations too, which stops
  # them being edited — but it does not compare them against the pair this
  # acquisition is running under, because this function receives neither. A plan
  # `plan/2` legitimately minted for another preparation and catalog sharing
  # this application's digest therefore still validates, and only
  # `declarations_honored/3` rejects it, after its closure has run callbacks.
  # Closing that needs the expected identities passed in here, which is part of
  # the `acquire/6`-`acquire_targets/7` unification.
  defp validate_plan(%{attestation: attestation} = plan, package)
       when is_binary(attestation) do
    with true <- Map.has_key?(plan, :package_digest),
         true <- plan.package_digest == package.application_content_digest,
         true <- Attestation.valid?(__MODULE__, payload(plan), attestation) do
      :ok
    else
      _invalid -> {:error, :invalid_provider_acquisition}
    end
  rescue
    _exception -> {:error, :invalid_provider_acquisition}
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
  defp declarations_honored(prepared, closure, session) do
    declared = Map.new(closure, &{site(&1), &1})

    case Enum.find(prepared, &(not honors_declaration?(&1, Map.get(declared, site(&1))))) do
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
      provider.data_class == declaration.data_class and
      Enum.sort(provider.accepts_data) == Enum.sort(declaration.accepts_data)
  end

  defp complete_acquisition(
         prepared,
         registry,
         session,
         effective_class,
         max_heap_words,
         credentials
       ) do
    with :ok <- credentials_honored(credentials, prepared, session),
         {:ok, preflighted} <- preflight_providers(prepared, session, max_heap_words) do
      try do
        with {:ok, resolved} <-
               provider_credentials(credentials, registry, preflighted, session),
             {:ok, acquired} <-
               acquire_providers(
                 preflighted,
                 resolved,
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
            capabilities: [{provider.index, built.capabilities} | environment.capabilities]
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

  # A supplied map is the active command's phase-8 step-5 result, and it is the
  # complete union the sealed declarations require. A preparation asking for a
  # name it does not contain has therefore widened its credentials past anything
  # the selection declared, so it is refused beside `declarations_honored/2` and
  # before preflight, where drift costs no further callback.
  #
  # This is a union bound, not a per-occurrence one: within the union a
  # preparation can still name a credential another selected provider declared.
  # `declarations_honored/2` closes that for targets because it has sealed
  # declarations to compare each preparation against; giving this path the same
  # check means threading those declarations through it, which is the
  # `acquire/6`–`acquire_targets/7` unification rather than a second check here.
  defp credentials_honored(nil, _prepared, _session), do: :ok

  defp credentials_honored(credentials, prepared, session) do
    covered = MapSet.new(Map.keys(credentials))

    case Enum.find(prepared, &(not MapSet.subset?(MapSet.new(&1.credential_names), covered))) do
      nil -> :ok
      drifting -> callback_error(:provider_declaration_mismatch, drifting, session)
    end
  end

  defp provider_credentials(credentials, _registry, _preflighted, _session)
       when is_map(credentials),
       do: {:ok, credentials}

  # Direct embedding: no sealed declarations to derive a union from before
  # preparation, and no operation deadline to bound it, so the registry's
  # synchronous resolution stays its documented contract. An active command is
  # refused here rather than silently served, because a command reaching this
  # branch would be resolving credentials a second time and outside its budget.
  defp provider_credentials(nil, registry, preflighted, session) do
    case ProviderSession.execution_deadline(session) do
      {:ok, nil} -> ProviderRegistry.resolve_credentials(registry, credential_names(preflighted))
      {:ok, _deadline} -> {:error, :invalid_provider_acquisition}
      :error -> {:error, :provider_session_unavailable}
    end
  end

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
