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
  alias PtcRunner.Kernel.ProviderCallbackBoundary
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar

  @type input_class :: :normal | :private_inspection
  @type artifact_preflight :: (input_class() -> :ok | {:error, term()})

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
  def acquire(package, registry, session, input_class, artifact_preflight),
    do: acquire_subset(package, registry, session, input_class, artifact_preflight, :all)

  @doc """
  Acquires a subset of one prepared run's selected providers.

  The subset names occurrence indices over the package's selected providers in
  `workflow`-then-`mission` order — the same indices the barrier already uses to
  identify an occurrence. `:all` is the whole application and is what an
  ordinary run and check pass.

  Every whole-application judgement stays whole-application, because narrowing
  them is how a subset would quietly become a weaker pipeline. All selected
  providers are prepared, and dependency validity, the single-workflow-LLM rule,
  the effective data class, and the providers' acceptance of that class are all
  decided over the complete set. Preparation is also the step that yields each
  provider's `requires`/`provides`, so the dependency closure below is computed
  from what the builders actually report rather than from a declaration that
  might disagree with them.

  Only the effectful steps narrow: the subset is expanded to its complete
  dependency closure, and preflight, the one credential union, and
  dependency-order acquisition cover exactly that closure. Providers pulled in
  only as dependencies are support work — they are acquired and cleaned up like
  any other, but a caller cannot tell them apart from its targets here and must
  not report them as results of its own.

  Ordering, cleanup, and failure behaviour are the barrier's throughout: partial
  acquisition unwinds in reverse, preflights are released once, and an
  unregistered closer is surfaced rather than dropped.
  """
  @spec acquire_subset(
          ApplicationPackage.t(),
          ProviderRegistry.t(),
          ProviderSession.t(),
          input_class(),
          artifact_preflight(),
          :all | [non_neg_integer()]
        ) ::
          {:ok, map()}
          | {:error, term()}
          | {:unregistered_provider_close, term(), ProviderRegistry.close()}
  def acquire_subset(
        %ApplicationPackage{} = package,
        %ProviderRegistry{} = registry,
        session,
        input_class,
        artifact_preflight,
        targets
      )
      when input_class in [:normal, :private_inspection] and
             is_function(artifact_preflight, 1) and
             (targets == :all or is_list(targets)) do
    max_heap_words = package.limits.provider_heap_words

    with {:ok, prepared} <-
           prepare_providers(package, registry, session, max_heap_words),
         :ok <- validate_provider_dependencies(prepared),
         :ok <- validate_single_workflow_llm(prepared),
         effective_class <- effective_data_class(input_class, prepared),
         :ok <- providers_accept(prepared, effective_class),
         :ok <- artifact_preflight.(effective_class),
         {:ok, selected} <- dependency_closure(prepared, targets),
         {:ok, preflighted} <- preflight_providers(selected, session, max_heap_words) do
      try do
        with {:ok, credentials} <-
               resolve_provider_credentials(
                 registry,
                 preflighted,
                 session,
                 max_heap_words
               ),
             {:ok, acquired} <-
               acquire_providers(
                 preflighted,
                 credentials,
                 effective_class,
                 session,
                 max_heap_words
               ) do
          {:ok,
           acquired
           |> Map.put(:workflow, finalize_capabilities(acquired.workflow))
           |> Map.put(:mission, finalize_capabilities(acquired.mission))
           |> Map.put(:snapshots, sort_snapshots(acquired.snapshots))
           |> Map.put(:provider_session, session)
           |> Map.delete(:exports)}
        end
      after
        ProviderCallbackBoundary.release_preflights(preflighted, session, max_heap_words)
      end
    end
  end

  def acquire_subset(
        _package,
        _registry,
        _session,
        _input_class,
        _artifact_preflight,
        _targets
      ),
      do: {:error, :invalid_provider_acquisition}

  # `:all` keeps the prepared list exactly as it is, so an ordinary run and
  # check reach the same providers in the same order they always did.
  defp dependency_closure(prepared, :all), do: {:ok, prepared}

  defp dependency_closure(prepared, targets) do
    by_index = Map.new(prepared, &{&1.index, &1})

    if Enum.all?(targets, &Map.has_key?(by_index, &1)) do
      {:ok, expand_closure(prepared, by_index, MapSet.new(targets))}
    else
      {:error, :invalid_provider_acquisition}
    end
  end

  # Dependencies are followed to a fixed point: a provider pulled in for its
  # service may require services of its own. Whole-set validation above already
  # proved every required service is provided exactly once, so this cannot
  # diverge and cannot silently drop an unsatisfiable requirement.
  defp expand_closure(prepared, by_index, selected) do
    providers_by_service =
      Enum.reduce(prepared, %{}, fn provider, accumulated ->
        Enum.reduce(provider.provides, accumulated, &Map.put(&2, &1, provider.index))
      end)

    closed = close_over(selected, by_index, providers_by_service)

    # The prepared order is the barrier's order; the closure is a filter on it
    # rather than a new sequence.
    Enum.filter(prepared, &MapSet.member?(closed, &1.index))
  end

  defp close_over(selected, by_index, providers_by_service) do
    added =
      selected
      |> Enum.flat_map(fn index -> Map.fetch!(by_index, index).requires end)
      |> Enum.map(&Map.get(providers_by_service, &1))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    next = MapSet.union(selected, added)

    if MapSet.equal?(next, selected),
      do: selected,
      else: close_over(next, by_index, providers_by_service)
  end

  defp sort_snapshots(snapshots), do: Enum.sort_by(snapshots, &Map.get(&1, "provider", ""))

  defp prepare_providers(package, registry, session, max_heap_words) do
    package
    |> provider_specs()
    |> Enum.with_index()
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

        {:error, _reason} ->
          {:halt, {:error, :provider_session_unavailable}}
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

  defp provider_specs(package) do
    for destination <- [:workflow, :mission],
        spec <- Map.fetch!(package.providers, destination),
        do: {destination, spec}
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
