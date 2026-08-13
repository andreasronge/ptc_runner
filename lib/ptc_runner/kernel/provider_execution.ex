defmodule PtcRunner.Kernel.ProviderExecution do
  @moduledoc false

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.ConnectivityProbe
  alias PtcRunner.Kernel.ConnectivityResult
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Authorization
  alias PtcRunner.Kernel.MCPOAuth.Context, as: OAuthContext
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderAcquisition
  alias PtcRunner.Kernel.ProviderActiveSession
  alias PtcRunner.Kernel.ProviderApplicationGate
  alias PtcRunner.Kernel.ProviderCredentials
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator

  @enforce_keys [:catalog, :services, :authorizations]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])
  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/

  @opaque t :: %__MODULE__{
            catalog: InstallationCatalog.t(),
            services: ProviderRuntimeServices.t(),
            authorizations: [binary()],
            attestation: binary() | nil
          }

  @type tracker ::
          (:put | :drop, :session | :registry | :memory | :listener, term() ->
             :ok | {:error, term()})

  @spec new(InstallationCatalog.t(), ProviderRuntimeServices.t(), [binary()]) ::
          {:ok, t()} | {:error, :invalid_provider_execution}
  def new(
        %InstallationCatalog{} = catalog,
        %ProviderRuntimeServices{} = services,
        authorizations
      )
      when is_list(authorizations) do
    execution = %__MODULE__{
      catalog: catalog,
      services: services,
      authorizations: authorizations
    }

    if valid_fields?(execution) do
      {:ok, %{execution | attestation: Attestation.attest(__MODULE__, payload(execution))}}
    else
      {:error, :invalid_provider_execution}
    end
  end

  def new(_catalog, _services, _authorizations),
    do: {:error, :invalid_provider_execution}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{attestation: attestation} = execution),
    do:
      Enum.sort(Map.keys(execution)) == @field_keys and valid_fields?(execution) and
        Attestation.valid?(__MODULE__, payload(execution), attestation)

  def valid?(_execution), do: false

  @doc """
  Checks that this execution requests no explicit authorization.

  `doctor --connect` must never notify or open an interaction, so it refuses an
  execution carrying authorization targets rather than quietly running the
  non-interactive path and reporting a check that skipped what was asked for.
  """
  @spec non_interactive?(term()) :: boolean()
  def non_interactive?(%__MODULE__{authorizations: []} = execution), do: valid?(execution)
  def non_interactive?(_execution), do: false

  @doc """
  Checks that this execution belongs to the exact preparation it will run.

  Callers must decide this before the owner consumes the prepared run, so an
  execution built from another catalog, or one requesting authorization for a
  provider the run never selected, leaves that preparation reusable.
  """
  @spec bound_to_prepared?(term(), term()) :: boolean()
  def bound_to_prepared?(%__MODULE__{} = execution, %PreparedRun{} = prepared) do
    valid?(execution) and prepared.catalog_attestation == execution.catalog.attestation and
      authorization_targets_valid?(execution, prepared)
  end

  def bound_to_prepared?(_execution, _prepared), do: false

  @doc false
  @spec execute(
          PreparedRun.t(),
          {PublicationAuthority.t(), PublicationAuthority.lease()},
          map(),
          t(),
          (binary() -> term()) | nil,
          tracker(),
          pid(),
          :run | :connect
        ) ::
          {:ok, PtcRunner.Kernel.ExecutionOutcome.t() | ConnectivityResult.t()}
          | {:error, term()}
  def execute(
        %PreparedRun{} = prepared,
        {authority, lease},
        opened_sinks,
        %__MODULE__{} = execution,
        notifier,
        tracker,
        lifecycle_owner,
        operation
      )
      when is_function(tracker, 3) and is_pid(lifecycle_owner) and
             operation in [:run, :connect] do
    do_execute(
      prepared,
      {authority, lease},
      opened_sinks,
      execution,
      notifier,
      tracker,
      lifecycle_owner,
      operation
    )
  end

  def execute(
        _prepared,
        _publication,
        _opened_sinks,
        _execution,
        _notifier,
        _tracker,
        _lifecycle_owner,
        _operation
      ),
      do: {:error, :invalid_provider_execution}

  @doc false
  @spec open_repl(
          PreparedRun.t(),
          PublicationAuthority.t(),
          map(),
          t(),
          tracker(),
          pid()
        ) :: {:ok, map()} | {:error, term()}
  def open_repl(
        %PreparedRun{} = prepared,
        authority,
        opened_sinks,
        %__MODULE__{} = execution,
        tracker,
        lifecycle_owner
      )
      when is_function(tracker, 3) and is_pid(lifecycle_owner) do
    do_execute(
      prepared,
      {authority, nil},
      opened_sinks,
      execution,
      nil,
      tracker,
      lifecycle_owner,
      :repl
    )
  end

  def open_repl(_prepared, _authority, _opened_sinks, _execution, _tracker, _lifecycle_owner),
    do: {:error, :invalid_provider_execution}

  defp do_execute(
         prepared,
         {authority, lease},
         opened_sinks,
         execution,
         notifier,
         tracker,
         lifecycle_owner,
         operation
       ) do
    if operation != :repl,
      do: Process.put({__MODULE__, :publication_lease}, lease)

    with true <- notifier_matches_operation?(notifier, operation),
         true <- valid?(execution),
         true <- operation != :connect or non_interactive?(execution),
         true <- PreparedRun.consumed_valid?(prepared),
         true <- PublicationAuthority.authorized?(authority),
         true <- publication_valid?(authority, lease, operation),
         true <- bound_to_prepared?(execution, prepared),
         :ok <- RunCoordinator.local_checks(prepared, execution.catalog, execution.services),
         {:ok, session} <-
           ProviderActiveSession.open_consumed_setup(
             prepared,
             execution.catalog,
             execution.services,
             lifecycle_owner,
             fn session -> tracker.(:put, :session, session) end
           ) do
      execute_with_session(
        prepared,
        authority,
        opened_sinks,
        execution,
        notifier,
        tracker,
        session,
        operation
      )
    else
      false -> {:error, :invalid_provider_execution}
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, internal_diagnostic()}
  catch
    _kind, _reason -> {:error, internal_diagnostic()}
  end

  # Connectivity carries no notifier at all, so the interactive branch below is
  # unreachable for it by construction rather than by the branch happening not
  # to be taken.
  defp notifier_matches_operation?(notifier, :connect), do: is_nil(notifier)

  defp notifier_matches_operation?(notifier, :repl), do: is_nil(notifier)

  defp notifier_matches_operation?(notifier, _operation),
    do: is_nil(notifier) or is_function(notifier, 1)

  defp publication_valid?(_authority, nil, :repl), do: true

  defp publication_valid?(authority, lease, _operation),
    do: PublicationAuthority.lease_valid?(authority, lease)

  defp execute_with_session(
         prepared,
         authority,
         opened_sinks,
         execution,
         notifier,
         tracker,
         session,
         operation
       ) do
    result =
      case unauthorized_oauth_alias(prepared, execution) do
        nil ->
          execute_authorized(
            prepared,
            authority,
            opened_sinks,
            execution,
            notifier,
            tracker,
            session,
            operation
          )

        name ->
          {:error,
           authorization_required_diagnostic(
             name,
             provider_application_activity?(prepared, execution)
           )}
      end

    result = classify_marked_failure(result, prepared)

    if operation == :repl,
      do: retain_or_close_repl(result, session, tracker),
      else: close_owned_session(result, session, tracker)
  end

  defp retain_or_close_repl({:ok, _built} = result, _session, _tracker), do: result

  defp retain_or_close_repl(result, session, tracker),
    do: close_owned_session(result, session, tracker)

  # Everything reachable from here has crossed the active lifecycle marker, so
  # a bare reason has lost the evidence needed to state whether work was
  # attempted. Typed diagnostics carry exact evidence; an untyped failure is
  # conservatively classified as active rather than making a false no-cost claim.
  #
  # Most of this region already answers with a diagnostic. Registry setup is the
  # exception — `registry_result/4` forwards a reason it has no classification
  # for — and an independent review found it by reading, not by any test, which
  # is why the invariant is enforced here rather than asserted in a comment.
  defp classify_marked_failure({:error, %CommandDiagnostic{}} = error, _prepared), do: error

  defp classify_marked_failure(
         {:error, {:missing_capability_requirement, names}},
         prepared
       ) do
    case RunBuilder.environment_failure_diagnostic(
           {:missing_capability_requirement, names},
           prepared,
           true
         ) do
      {:ok, diagnostic} -> {:error, diagnostic}
      :error -> {:error, internal_diagnostic()}
    end
  end

  defp classify_marked_failure({:error, _reason}, _prepared),
    do: {:error, internal_diagnostic()}

  defp classify_marked_failure(result, _prepared), do: result

  defp execute_authorized(
         prepared,
         authority,
         opened_sinks,
         execution,
         notifier,
         tracker,
         session,
         operation
       ) do
    if execution.authorizations == [] do
      execute_ordinary(
        prepared,
        authority,
        opened_sinks,
        execution,
        tracker,
        session,
        operation
      )
    else
      execute_after_authorization(
        prepared,
        authority,
        opened_sinks,
        execution,
        notifier,
        tracker,
        session,
        operation
      )
    end
  end

  # Standalone V1 disables OAuth execution: `mix ptc run --authorize-mcp NAME` is
  # the only shipped path to a grant, so a selected OAuth occurrence nobody named
  # has no store to draw one from. It used to walk into acquisition against an
  # empty one and fail with whatever that path produced.
  #
  # The refusal sits here, before either branch, because both are cost this
  # command cannot use. The interactive branch would open a browser interaction
  # for one alias before discovering another can never be served, and the
  # ordinary branch would run active selection validators and unverified local
  # checks — unrestricted active work — for a selection that is already refused.
  # That is the same rule the validator/unverified ordering rests on.
  #
  # It is nevertheless past the phase-8 marker, which `active_preflight` requires
  # and the OAuth contract states. The marker makes the refusal admissible but is
  # not activity evidence: only successful command-owned application admission
  # may already have attempted provider-facing work here.
  #
  # `PtcRunner.Kernel.AcquisitionReason` mints this same code for the different
  # question of an authorization failing underneath an alias that *was*
  # authorized — a revoked grant, a failed refresh — discovered mid-acquisition.
  # The two cannot both answer for one alias: reaching acquisition at all means
  # this refusal did not fire. They are told apart by their subject, because
  # authorization is per alias while a mid-acquisition failure knows the exact
  # occurrence that hit it.
  defp unauthorized_oauth_alias(prepared, execution) do
    authorized = MapSet.new(execution.authorizations)

    Enum.find_value(prepared.provider_declarations, fn %{name: name} ->
      if not MapSet.member?(authorized, name) and
           match?(%{authorization_mode: :oauth}, execution.catalog.descriptors[name]),
         do: name
    end)
  end

  # A failed session close outranks the result it would otherwise hide, matching
  # `ProviderActiveSession`'s fail-closed policy. This deliberately runs outside
  # an `after` block: a raised body must leave the session registered so the
  # lifecycle owner still closes it rather than dropping it untracked and open.
  defp close_owned_session(result, session, tracker) do
    cleanup = if ProviderSession.alive?(session), do: ProviderSession.close(session), else: :ok
    _ = tracker.(:drop, :session, session)

    case cleanup do
      :ok -> result
      {:error, _reason} -> {:error, cleanup_diagnostic()}
    end
  end

  defp execute_ordinary(prepared, authority, opened_sinks, execution, tracker, session, operation) do
    selected_names = selected_provider_names(prepared)

    with {:ok, session} <-
           ProviderActiveSession.begin_owned_operation(
             session,
             prepared,
             execution.catalog,
             execution.services,
             provider_operation(operation)
           ),
         {:ok, authorities} <- oauth_authorities(execution, selected_names),
         deadline <-
           oauth_operation_deadline(
             ProviderSession.run_deadline(session),
             prepared.provider_declarations,
             authorities,
             System.monotonic_time(:millisecond)
           ) do
      with_runtime_registry(
        execution,
        ProviderSession.lifecycle_owner(session),
        selected_names,
        authorities,
        deadline,
        tracker,
        {operation, precredential_activity?(prepared, execution)},
        fn registry ->
          complete(prepared, authority, opened_sinks, registry, session, execution, operation)
        end
      )
    end
  end

  defp execute_after_authorization(
         prepared,
         authority,
         opened_sinks,
         execution,
         notifier,
         tracker,
         session,
         operation
       ) do
    selected_names = selected_provider_names(prepared)

    with {:ok, authorities} <- oauth_authorities(execution, selected_names),
         deadline when not is_nil(deadline) <-
           oauth_setup_deadline(
             prepared.provider_declarations,
             authorities,
             selected_names,
             System.monotonic_time(:millisecond)
           ) do
      with_runtime_registry(
        execution,
        ProviderSession.lifecycle_owner(session),
        selected_names,
        authorities,
        deadline,
        tracker,
        {{:authorization, selected_names}, provider_application_activity?(prepared, execution)},
        fn registry, context ->
          with :ok <-
                 authorize_installations(
                   context,
                   registry,
                   prepared.provider_declarations,
                   authorities,
                   execution.authorizations,
                   notifier,
                   tracker,
                   session
                 )
                 |> authorization_result(selected_names, execution.catalog),
               {:ok, session} <-
                 ProviderActiveSession.begin_owned_operation(
                   session,
                   prepared,
                   execution.catalog,
                   execution.services,
                   provider_operation(operation)
                 ) do
            resolve_credentials_and_complete(
              prepared,
              authority,
              opened_sinks,
              registry,
              session,
              execution,
              operation,
              true
            )
          end
        end
      )
    else
      nil -> {:error, :invalid_mcp_authorization}
      {:error, _reason} = error -> error
    end
  end

  # Phase-8 step 5, and the one place any active command resolves an ordinary
  # credential. It sits here rather than inside either branch because the branch
  # is exactly what must not decide it: acquisition answers for the closure it
  # acquires, and a `:none` occurrence declaring a credential is inside no
  # closure, so a connectivity-local remainder pass would be a second credential
  # pipeline with a different derivation rule.
  #
  # Reached from both the ordinary and the post-authorization branch, so the
  # registry and the OAuth context already exist and no provider prepare,
  # preflight, acquisition, or execution callback below this line has run yet.
  # The branch still supplies whether authorization or an earlier active step
  # actually attempted provider-facing work. The lifecycle marker alone is not
  # evidence: inert application rejection and ordinary credential lookup both
  # occur after it.
  defp complete(prepared, authority, opened_sinks, registry, session, execution, operation),
    do:
      resolve_credentials_and_complete(
        prepared,
        authority,
        opened_sinks,
        registry,
        session,
        execution,
        operation,
        precredential_activity?(prepared, execution)
      )

  defp resolve_credentials_and_complete(
         prepared,
         authority,
         opened_sinks,
         registry,
         session,
         execution,
         operation,
         provider_activity
       ) do
    with {:ok, credentials} <-
           ProviderCredentials.resolve(
             prepared,
             execution.catalog,
             registry,
             session,
             provider_activity
           ) do
      complete(
        prepared,
        authority,
        opened_sinks,
        registry,
        session,
        execution,
        operation,
        credentials
      )
    end
  end

  defp precredential_activity?(prepared, execution) do
    provider_application_activity?(prepared, execution) or
      Enum.any?(prepared.provider_declarations, fn declaration ->
        descriptor = Map.fetch!(execution.catalog.descriptors, declaration.name)

        declaration.validation_state == :active_required or
          descriptor.local_preflight == :unverified
      end)
  end

  defp provider_application_activity?(prepared, execution),
    do:
      ProviderApplicationGate.startup_attempted_after_admission?(
        prepared,
        execution.catalog,
        execution.services
      )

  # Every step above this one is shared by a run and connectivity: the
  # same active-lifecycle marker, session, registry, credentials, OAuth, and cleanup
  # ownership. Only the completion differs, so none of them can drift into its
  # own provider lifecycle.
  defp complete(
         prepared,
         authority,
         opened_sinks,
         registry,
         session,
         execution,
         operation,
         credentials
       )
       when operation == :run,
       do:
         build_and_complete(
           prepared,
           authority,
           opened_sinks,
           registry,
           session,
           execution.catalog,
           operation,
           credentials
         )

  defp complete(
         prepared,
         authority,
         opened_sinks,
         registry,
         session,
         execution,
         :repl,
         credentials
       ),
       do:
         build_and_complete(
           prepared,
           authority,
           opened_sinks,
           registry,
           session,
           execution.catalog,
           :repl,
           credentials
         )

  # Connectivity is the one completion that does not build a run config. A run
  # acquires every selected provider to reach its result;
  # connectivity decides per occurrence what its declaration asks for, so
  # building one here would acquire providers a `:none` occurrence never wanted.
  defp complete(
         prepared,
         _authority,
         _opened_sinks,
         registry,
         session,
         execution,
         :connect,
         credentials
       ),
       do: complete_connectivity(prepared, execution, registry, session, credentials)

  defp build_and_complete(
         prepared,
         authority,
         opened_sinks,
         registry,
         session,
         catalog,
         operation,
         credentials
       ) do
    with {:ok, built} <-
           RunBuilder.build_active_owned(
             prepared,
             catalog,
             registry,
             session,
             authority,
             opened_sinks,
             credentials
           ) do
      case operation do
        :run ->
          complete_operation(
            Map.put(built, :publication_lease, Process.get({__MODULE__, :publication_lease})),
            operation
          )

        :repl ->
          {:ok, built}
      end
    end
  end

  defp provider_operation(:repl), do: :run
  defp provider_operation(operation), do: operation

  # Applicability comes from the sealed descriptor of each selected occurrence,
  # so no caller can narrow the work or reorder it. The deadline the session
  # claimed bounds the whole operation; `:none` occurrences spend none of it,
  # because a declaration that asks for no connectivity is answered without a
  # credential, a callback, or a provider.
  #
  # Execution order is pinned and is deliberately not the reporting order.
  # Acquisition targets go first, through the shared dependency-order barrier,
  # because only that barrier can make a target's prerequisites available to it
  # and a probe must not spend the budget a closure still needs. Probes follow
  # in declaration order. The first execution failure returns its own
  # diagnostic, naming the occurrence that actually failed rather than the
  # earliest declared one.
  #
  # The entries are the canonical success projection. They are derived inertly
  # from sealed declarations, and are sealed into a result only once every
  # execution step above has succeeded, so no entry can report an occurrence
  # nothing reached.
  defp complete_connectivity(prepared, execution, registry, session, credentials) do
    prepared
    |> connectivity_result(execution, registry, session, credentials)
    |> close_connectivity_session(session)
  end

  # The session closes here, inside the registry callback, exactly where a run
  # closes its own. Its committed closers belong to the runtime that
  # acquired them — a connectivity acquisition commits real ones — so unwinding
  # the registry first would leave a closer reaching for authority that is
  # already gone. That is the owner's session-before-runtime ordering, and
  # connectivity was the one completion that inverted it.
  #
  # A cleanup failure outranks the result it would otherwise hide, matching
  # `close_owned_session/3`, which then finds the session already closed and
  # drops only its tracker entry.
  defp close_connectivity_session(result, session) do
    cleanup = if ProviderSession.alive?(session), do: ProviderSession.close(session), else: :ok

    case cleanup do
      :ok -> result
      {:error, _reason} -> {:error, cleanup_diagnostic()}
    end
  end

  defp connectivity_result(prepared, execution, registry, session, credentials) do
    catalog = execution.catalog

    with true <- ProviderRegistry.valid?(registry),
         true <- ProviderSession.alive?(session),
         deadline when not is_nil(deadline) <- ProviderSession.run_deadline(session),
         {:ok, entries} <- connectivity_entries(prepared, catalog),
         :ok <-
           acquire_connectivity_targets(
             prepared,
             catalog,
             registry,
             session,
             entries,
             credentials
           ),
         activity_before_probe =
           precredential_activity?(prepared, execution) or
             Enum.any?(entries, &(&1.mode == :acquisition)),
         {:ok, provider_activity} <-
           ConnectivityProbe.run(
             prepared,
             catalog,
             execution.services,
             deadline,
             credentials,
             activity_before_probe
           ),
         {:ok, result} <-
           ConnectivityResult.new(prepared, catalog, entries, provider_activity) do
      if Deadline.expired?(deadline),
        do: {:error, connectivity_timeout_diagnostic(provider_activity)},
        else: {:ok, result}
    else
      {:error, %CommandDiagnostic{}} = error -> error
      _invalid -> {:error, internal_diagnostic()}
    end
  end

  # The targets are the `:acquisition` occurrences themselves.
  # `ProviderAcquisition` closes over their sealed dependencies and acquires
  # only that closure, so a provider pulled in as a prerequisite is acquired and
  # cleaned up like any other while never becoming a connectivity entry of its
  # own. Connectivity publishes nothing, so it authorizes no artifact, and the
  # acquired closure stays on the session's LIFO stack for the ordinary close
  # rather than unwinding through a path of its own.
  defp acquire_connectivity_targets(prepared, catalog, registry, session, entries, credentials) do
    case Enum.filter(entries, &(&1.mode == :acquisition)) do
      [] ->
        :ok

      targets ->
        prepared
        |> ProviderAcquisition.acquire(
          catalog,
          registry,
          session,
          Enum.map(targets, &Map.take(&1, [:destination, :index])),
          credentials
        )
        |> acquisition_result(session)
    end
  end

  defp acquisition_result({:ok, _acquired}, _session), do: :ok
  defp acquisition_result({:error, %CommandDiagnostic{}} = error, _session), do: error

  # A closer the session could not adopt has no owner, so it is run with the
  # session rather than dropped. The reason travelling with it is sometimes a
  # catalogued diagnostic — an expired acquisition preserves the one that
  # described the failure — and discarding that in favour of an internal error
  # would throw away the only accurate account of what went wrong. A bare
  # reason carries no occurrence to attribute it to, so that case still fails
  # closed. A cleanup failure outranks either, because it is the newer fact.
  defp acquisition_result({:unregistered_provider_close, reason, close}, session) do
    case ProviderSession.close_with_unregistered(session, close) do
      :ok -> {:error, unregistered_diagnostic(reason)}
      {:error, _reason} -> {:error, cleanup_diagnostic()}
    end
  end

  defp acquisition_result({:error, _reason}, _session), do: {:error, internal_diagnostic()}

  defp unregistered_diagnostic(%CommandDiagnostic{} = diagnostic), do: diagnostic
  defp unregistered_diagnostic(_reason), do: internal_diagnostic()

  # Evidence that arrives after the operation's own cutoff is not evidence the
  # operation may report. Registry setup can finish near the connectivity
  # deadline and this process can resume past it, so success is confirmed
  # against the deadline rather than assumed from having reached the end.
  # The operation-wide code, not the per-occurrence one. An exhausted budget is
  # not a provider being temporarily unreachable: `connectivity_unavailable` is
  # retriable and carries the occurrence that failed, while an exhausted budget
  # is non-retriable and belongs to the operation, so it carries no subject.
  # `ConnectivityProbe` already reports a spent budget this way, and the two
  # paths must not disagree about what the same condition means.
  defp connectivity_timeout_diagnostic(provider_activity) do
    CommandDiagnostic.new!(:active_preflight, :connectivity_timeout,
      provider_activity: provider_activity
    )
  end

  # A sealed declaration carries an inert projection, not its descriptor, so the
  # declared mode is read from the catalog the preparation was validated
  # against. `ConnectivityResult.new/4` re-derives every mode from that same
  # catalog and refuses a result whose entries disagree, because alias names are
  # not identity.
  defp connectivity_entries(prepared, catalog) do
    Enum.reduce_while(prepared.provider_declarations, {:ok, []}, fn declaration, {:ok, entries} ->
      case connectivity_entry(declaration, catalog.descriptors[declaration.name]) do
        {:ok, entry} -> {:cont, {:ok, entries ++ [entry]}}
        {:error, _diagnostic} = error -> {:halt, error}
      end
    end)
  end

  defp connectivity_entry(declaration, %{connectivity_mode: mode})
       when mode in [:none, :probe, :acquisition] do
    {:ok,
     %{
       name: declaration.name,
       destination: declaration.destination,
       index: declaration.index,
       mode: mode,
       outcome: if(mode == :none, do: :skipped, else: :reachable)
     }}
  end

  defp connectivity_entry(_declaration, _descriptor), do: {:error, internal_diagnostic()}

  defp complete_operation(%{publication_lease: lease} = built, :run),
    do: RunBuilder.execute_built_claimed(built, lease)

  defp with_runtime_registry(
         execution,
         lifecycle_owner,
         selected_names,
         authorities,
         deadline,
         tracker,
         operation_context,
         callback
       ) do
    if map_size(authorities) == 0 do
      with_registry(
        execution.catalog,
        execution.services,
        lifecycle_owner,
        selected_names,
        deadline,
        tracker,
        operation_context,
        callback
      )
    else
      with_memory_runtime(
        execution,
        lifecycle_owner,
        selected_names,
        deadline,
        tracker,
        operation_context,
        callback
      )
    end
  end

  # The store belongs to the lifecycle owner, not to this bounded worker.
  # Terminating a worker blocked in provider work must not destroy the store a
  # committed provider closer still needs while the session closes.
  defp with_memory_runtime(
         execution,
         lifecycle_owner,
         selected_names,
         deadline,
         tracker,
         operation_context,
         callback
       ) do
    with {:ok, memory} <- Memory.start(owner: lifecycle_owner),
         :ok <- tracked_memory(tracker, memory) do
      try do
        with {:ok, store} <- Memory.store(memory),
             {:ok, context} <-
               OAuthContext.new(
                 tenant_id: "local-cli",
                 principal_id: "local-user",
                 store: store,
                 deadline: deadline
               ),
             {:ok, services} <-
               ProviderRuntimeServices.with_oauth_context(
                 execution.services,
                 deadline,
                 context
               ) do
          with_registry(
            execution.catalog,
            services,
            lifecycle_owner,
            selected_names,
            deadline,
            tracker,
            operation_context,
            registry_callback(callback, context)
          )
        end
      after
        Memory.close(memory)
        _ = tracker.(:drop, :memory, memory)
      end
    else
      {:error, _reason} = error -> error
    end
  end

  # The authorization branch's callback also needs the shared OAuth context.
  # Binding it here keeps one registry-opening shape rather than teaching that
  # step which branch supplied its callback.
  defp registry_callback(callback, context) when is_function(callback, 2),
    do: fn registry -> callback.(registry, context) end

  defp registry_callback(callback, _context) when is_function(callback, 1), do: callback

  # An untracked store has no owner that would close it, and it is no longer
  # linked to this worker, so a refused registration closes it here instead of
  # leaving it to the lifecycle owner's own death.
  defp tracked_memory(tracker, memory) do
    case tracker.(:put, :memory, memory) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        Memory.close(memory)
        error
    end
  end

  # The registry is opened for the lifecycle owner, not for this worker: a
  # host-bound authority is revoked when its owner dies, and the owner must be
  # able to close resources acquired through the registry after terminating a
  # worker that is blocked in provider work.
  defp with_registry(
         catalog,
         services,
         lifecycle_owner,
         selected_names,
         deadline,
         tracker,
         {operation, _provider_activity} = operation_context,
         callback
       ) do
    result =
      InstallationCatalog.runtime_registry(
        catalog,
        services,
        selected_names,
        deadline,
        lifecycle_owner
      )
      |> registry_result(operation_context, selected_names, catalog)

    with {:ok, registry} <- result,
         :ok <- tracker.(:put, :registry, registry) do
      result = callback.(registry)

      if operation == :repl and match?({:ok, _built}, result) do
        result
      else
        ProviderRegistry.close(registry)
        _ = tracker.(:drop, :registry, registry)
        result
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp registry_result({:ok, registry}, _operation_context, _selected_names, _catalog),
    do: {:ok, registry}

  defp registry_result(
         {:error, :operation_deadline_expired},
         {operation, _provider_activity},
         _selected_names,
         _catalog
       )
       when operation == :run,
       do: {:error, CommandDiagnostic.new!(:execution, :run_timeout, provider_activity: true)}

  defp registry_result(
         {:error, :operation_deadline_expired},
         {:repl, _provider_activity},
         _selected_names,
         _catalog
       ),
       do: {:error, CommandDiagnostic.new!(:execution, :run_timeout, provider_activity: true)}

  # Connectivity spends a different budget, so exhausting it is not a run
  # timeout. `execution/run_timeout` also names a phase the connect contract
  # does not admit, which would turn a spent connectivity budget into an
  # unrenderable outcome.
  defp registry_result(
         {:error, :operation_deadline_expired},
         {:connect, provider_activity},
         _selected_names,
         _catalog
       ),
       do: {:error, connectivity_timeout_diagnostic(provider_activity)}

  defp registry_result(
         {:error, reason},
         {{:authorization, selected_names}, provider_activity},
         _ignored,
         catalog
       )
       when reason in [:operation_deadline_expired, :timeout] do
    name =
      selected_names
      |> Enum.filter(&(catalog.descriptors[&1].authorization_mode == :oauth))
      |> Enum.min()

    {:error, authorization_diagnostic(name, provider_activity)}
  end

  defp registry_result(
         {:error, _reason} = error,
         _operation_context,
         _selected_names,
         _catalog
       ),
       do: error

  defp oauth_authorities(execution, selected_names) do
    with {:ok, authorities} <-
           ProviderRuntimeServices.oauth_authorities(execution.services, selected_names),
         true <- authorities_match_catalog?(authorities, execution.catalog, selected_names) do
      {:ok, authorities}
    else
      _invalid -> {:error, :invalid_provider_execution}
    end
  end

  defp authorities_match_catalog?(authorities, catalog, selected_names)
       when is_map(authorities) and not is_struct(authorities) do
    expected =
      selected_names
      |> Enum.filter(&(catalog.descriptors[&1].authorization_mode == :oauth))
      |> Enum.sort()

    Enum.sort(Map.keys(authorities)) == expected and
      Enum.all?(authorities, fn {name, authority} ->
        descriptor = catalog.descriptors[name]

        Authority.valid?(authority) and
          authority.fingerprint == descriptor.authority_fingerprint
      end)
  end

  defp authorities_match_catalog?(_authorities, _catalog, _selected_names), do: false

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

  @doc false
  @spec authorization_result(:ok | {:error, term()}, [binary()], InstallationCatalog.t()) ::
          :ok | {:error, term()}
  def authorization_result(:ok, _selected_names, _catalog), do: :ok

  def authorization_result({:error, {:authorization_timeout, name}}, _selected_names, _catalog),
    do: {:error, authorization_diagnostic(name)}

  def authorization_result(
        {:error, {:authorization_unavailable, name}},
        _selected_names,
        _catalog
      ),
      do: {:error, authorization_diagnostic(name)}

  def authorization_result({:error, reason}, selected_names, catalog)
      when reason in [:operation_deadline_expired, :timeout] do
    name =
      selected_names
      |> Enum.filter(&(catalog.descriptors[&1].authorization_mode == :oauth))
      |> Enum.min()

    {:error, authorization_diagnostic(name)}
  end

  def authorization_result({:error, _reason} = error, _selected_names, _catalog), do: error

  defp authorize_installations(
         context,
         registry,
         declarations,
         authorities,
         requested,
         notifier,
         tracker,
         session
       ) do
    Enum.reduce_while(requested, :ok, fn name, :ok ->
      authority = Map.get(authorities, name)

      deadline =
        oauth_target_deadline(
          name,
          declarations,
          authorities,
          System.monotonic_time(:millisecond)
        )

      result =
        with %Authority{} <- authority,
             true <- Deadline.valid?(deadline),
             {:ok, authority_epoch} <-
               ProviderRegistry.oauth_authority_epoch(registry, name, deadline),
             :ok <-
               authorize_installation(
                 context,
                 authority,
                 authority_epoch,
                 deadline,
                 notifier,
                 tracker,
                 session
               ) do
          :ok
        else
          false ->
            {:error, :invalid_mcp_authorization}

          nil ->
            {:error, :invalid_mcp_authorization}

          {:error, reason} when reason in [:timeout, :authorization_timeout] ->
            {:error, {:authorization_timeout, name}}

          {:error, reason}
          when reason in [:authorization_context_required, :authorization_unavailable] ->
            {:error, {:authorization_unavailable, name}}

          {:error, _reason} = error ->
            error
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp authorize_installation(
         context,
         authority,
         authority_epoch,
         deadline,
         notifier,
         tracker,
         session
       ) do
    with true <- Authority.cli_compatible?(authority),
         {:ok, listener} <- LoopbackListener.start(authority),
         :ok <- tracker.(:put, :listener, listener) do
      try do
        authorize_with_listener(
          context,
          authority,
          authority_epoch,
          deadline,
          listener,
          notifier,
          session
        )
      after
        LoopbackListener.close(listener)
        _ = tracker.(:drop, :listener, listener)
      end
    else
      false -> {:error, :mcp_authorization_not_cli_compatible}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_with_listener(
         context,
         authority,
         authority_epoch,
         deadline,
         listener,
         notifier,
         session
       ) do
    case Authorization.begin_authorization(context, authority,
           authority_epoch: authority_epoch,
           deadline_ms: Deadline.expires_at(deadline),
           redirect_uri: listener.redirect_uri
         ) do
      {:ok, pending} ->
        case notify(notifier, pending.url, deadline) do
          :ok ->
            case LoopbackListener.await(listener, context, pending, cleanup_opts(session)) do
              {:ok, _grant} -> :ok
              {:error, _reason} = error -> error
            end

          {:error, _reason} = error ->
            cancel_pending(context, pending, session, error)
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Terminal cleanup spends the one budget the lifecycle owner installed, and
  # the session anchors it when cleanup actually begins. Anchoring lazily is the
  # point: the interaction this accompanies may run for its whole authorization
  # timeout before anything fails, and an eagerly anchored deadline would
  # already be spent by then.
  defp cleanup_opts(session),
    do: [anchor_cleanup_deadline: fn -> ProviderSession.anchor_cleanup_deadline(session) end]

  defp cancel_pending(context, pending, session, error) do
    with {:ok, deadline} <- ProviderSession.anchor_cleanup_deadline(session),
         :ok <-
           Authorization.cancel_authorization(context, pending, cleanup_deadline: deadline) do
      error
    else
      _unsettled -> {:error, :authorization_cleanup_failed}
    end
  end

  defp notify(notifier, url, deadline) when is_function(notifier, 1) do
    case Deadline.remaining(deadline) do
      0 ->
        {:error, :authorization_timeout}

      timeout_ms ->
        case BoundedWorker.run(fn -> notifier.(url) end,
               timeout_ms: timeout_ms,
               max_heap_words: 100_000,
               cancel_with_caller: true
             ) do
          {:ok, :ok} -> :ok
          {:error, :timeout} -> {:error, :authorization_timeout}
          _failure -> {:error, :authorization_unavailable}
        end
    end
  end

  defp notify(nil, _url, _deadline), do: {:error, :authorization_unavailable}

  defp authorization_targets_valid?(execution, prepared) do
    selected = MapSet.new(prepared.provider_declarations, & &1.name)

    Enum.all?(execution.authorizations, fn name ->
      MapSet.member?(selected, name) and
        match?(%{authorization_mode: :oauth}, execution.catalog.descriptors[name])
    end)
  end

  defp selected_provider_names(prepared),
    do: prepared.provider_declarations |> Enum.map(& &1.name) |> Enum.uniq()

  defp valid_fields?(execution) do
    InstallationCatalog.valid?(execution.catalog) and
      ProviderRuntimeServices.bound_to?(execution.services, execution.catalog.runtime_binding) and
      length(execution.authorizations) <= 128 and
      execution.authorizations == Enum.uniq(execution.authorizations) and
      Enum.all?(execution.authorizations, fn name ->
        is_binary(name) and name =~ @name and
          match?(%{authorization_mode: :oauth}, execution.catalog.descriptors[name])
      end)
  end

  defp payload(execution),
    do: {execution.catalog, execution.services, execution.authorizations}

  defp authorization_diagnostic(name, provider_activity \\ true) do
    {:ok, subject} = CommandSubject.provider(name, :authorization)

    CommandDiagnostic.new!(:active_preflight, :authorization_unavailable,
      provider_activity: provider_activity,
      subject: subject
    )
  end

  # Attribution is per alias and carries no occurrence, because a grant, an
  # authority, and a store are all per alias: every occurrence of one alias
  # shares the single authorization that is missing, so naming one of them would
  # be arbitrary. The alias reported is the first in manifest order, the same
  # deterministic rule credential attribution uses.
  defp authorization_required_diagnostic(name, provider_activity) do
    {:ok, subject} = CommandSubject.provider(name, :authorization)

    CommandDiagnostic.new!(:active_preflight, :authorization_required,
      provider_activity: provider_activity,
      subject: subject
    )
  end

  defp cleanup_diagnostic,
    do: CommandDiagnostic.new!(:result_cleanup, :provider_cleanup_failed, provider_activity: true)

  defp internal_diagnostic,
    do: CommandDiagnostic.new!(:internal, :internal_error, provider_activity: true)
end
