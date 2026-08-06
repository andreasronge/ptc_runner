defmodule PtcRunner.Kernel.ProviderExecution do
  @moduledoc false

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Authorization
  alias PtcRunner.Kernel.MCPOAuth.Context, as: OAuthContext
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActiveSession
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder

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
          PublicationAuthority.t(),
          map(),
          t(),
          (binary() -> term()),
          tracker(),
          pid(),
          :run | :check
        ) ::
          {:ok, PtcRunner.Kernel.ExecutionOutcome.t() | [map()]} | {:error, term()}
  def execute(
        %PreparedRun{} = prepared,
        authority,
        opened_sinks,
        %__MODULE__{} = execution,
        notifier,
        tracker,
        lifecycle_owner,
        operation
      )
      when is_function(notifier, 1) and is_function(tracker, 3) and is_pid(lifecycle_owner) and
             operation in [:run, :check] do
    with true <- valid?(execution),
         true <- PreparedRun.consumed_valid?(prepared),
         true <- PublicationAuthority.valid?(authority),
         true <- bound_to_prepared?(execution, prepared),
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

  def execute(
        _prepared,
        _authority,
        _opened_sinks,
        _execution,
        _notifier,
        _tracker,
        _lifecycle_owner,
        _operation
      ),
      do: {:error, :invalid_provider_execution}

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

    close_owned_session(result, session, tracker)
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
           ProviderActiveSession.begin_owned_run(session, prepared, execution.catalog),
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
        selected_names,
        authorities,
        deadline,
        tracker,
        :run,
        fn registry ->
          build_and_complete(prepared, authority, opened_sinks, registry, session, operation)
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
        selected_names,
        authorities,
        deadline,
        tracker,
        {:authorization, selected_names},
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
                 ProviderActiveSession.begin_owned_run(session, prepared, execution.catalog) do
            build_and_complete(prepared, authority, opened_sinks, registry, session, operation)
          end
        end
      )
    else
      nil -> {:error, :invalid_mcp_authorization}
      {:error, _reason} = error -> error
    end
  end

  # Every step above this one is shared by a run and a check: the same activity
  # marker, session, registry, credentials, OAuth, acquisition, and cleanup
  # ownership. Only the completion differs, so a check cannot drift into its own
  # provider lifecycle.
  defp build_and_complete(prepared, authority, opened_sinks, registry, session, operation) do
    with {:ok, built} <-
           RunBuilder.build_active_owned(
             prepared,
             registry,
             session,
             authority,
             opened_sinks
           ) do
      complete_operation(built, operation)
    end
  end

  defp complete_operation(built, :run), do: RunBuilder.execute_built(built)
  defp complete_operation(built, :check), do: RunBuilder.check_built(built)

  defp with_runtime_registry(
         execution,
         selected_names,
         authorities,
         deadline,
         tracker,
         operation,
         callback
       ) do
    if map_size(authorities) == 0 do
      with_registry(
        execution.catalog,
        execution.services,
        selected_names,
        deadline,
        tracker,
        operation,
        callback,
        nil
      )
    else
      with_memory_runtime(
        execution,
        selected_names,
        deadline,
        tracker,
        operation,
        callback
      )
    end
  end

  defp with_memory_runtime(
         execution,
         selected_names,
         deadline,
         tracker,
         operation,
         callback
       ) do
    with {:ok, memory} <- Memory.start_link(owner: self()),
         :ok <- tracker.(:put, :memory, memory) do
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
            selected_names,
            deadline,
            tracker,
            operation,
            callback,
            context
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

  defp with_registry(
         catalog,
         services,
         selected_names,
         deadline,
         tracker,
         operation,
         callback,
         context
       ) do
    result =
      InstallationCatalog.runtime_registry(catalog, services, selected_names, deadline)
      |> registry_result(operation, selected_names, catalog)

    with {:ok, registry} <- result,
         :ok <- tracker.(:put, :registry, registry) do
      try do
        if is_nil(context), do: callback.(registry), else: callback.(registry, context)
      after
        ProviderRegistry.close(registry)
        _ = tracker.(:drop, :registry, registry)
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp registry_result({:ok, registry}, _operation, _selected_names, _catalog),
    do: {:ok, registry}

  defp registry_result(
         {:error, :operation_deadline_expired},
         :run,
         _selected_names,
         _catalog
       ),
       do: {:error, CommandDiagnostic.new!(:execution, :run_timeout, provider_activity: true)}

  defp registry_result(
         {:error, reason},
         {:authorization, selected_names},
         _ignored,
         catalog
       )
       when reason in [:operation_deadline_expired, :timeout] do
    name =
      selected_names
      |> Enum.filter(&(catalog.descriptors[&1].authorization_mode == :oauth))
      |> Enum.min()

    {:error, authorization_diagnostic(name)}
  end

  defp registry_result({:error, _reason} = error, _operation, _selected_names, _catalog),
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

  defp notify(notifier, url, deadline) do
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

  defp authorization_diagnostic(name) do
    {:ok, subject} = CommandSubject.provider(name, :authorization)

    CommandDiagnostic.new!(:active_preflight, :authorization_unavailable,
      provider_activity: true,
      subject: subject
    )
  end

  defp cleanup_diagnostic,
    do: CommandDiagnostic.new!(:result_cleanup, :provider_cleanup_failed, provider_activity: true)

  defp internal_diagnostic,
    do: CommandDiagnostic.new!(:internal, :internal_error, provider_activity: true)
end
