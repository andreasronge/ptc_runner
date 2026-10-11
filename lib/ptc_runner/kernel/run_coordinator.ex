defmodule PtcRunner.Kernel.RunCoordinator do
  @moduledoc """
  Path-free preparation and one-shot execution.

  Bundle compilation, public-entry validation, and decidable provider-free
  mission capability validation run before provider declarations. Provider
  declaration checks inspect only installed aliases;
  they never invoke a builder, credential resolver, preflight callback, OAuth
  context, store, process, or network operation.

  One-shot execution consumes the prepared run inside an execution-session
  owner. That owner constructs both sinks, keeps responding to caller death
  while a subordinate worker performs provider setup and runs the Kernel, and
  returns only sealed, filesystem-path-free execution evidence. Publication
  remains a separate caller operation.
  """

  alias PtcRunner.Kernel.ConnectivityResult
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.Progress
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunPreparation

  @doc "Compiles and validates a sealed request through `PtcRunner.Kernel.RunPreparation`."
  defdelegate prepare(request, catalog), to: RunPreparation
  defdelegate local_checks(prepared, catalog, services), to: RunPreparation
  @doc false
  defdelegate local_checks(prepared, catalog, services, target), to: RunPreparation
  defdelegate declared_input_checks(prepared, catalog, services), to: RunPreparation
  defdelegate local_check_findings(prepared, catalog, services), to: RunPreparation
  @doc false
  defdelegate classify_bundle_failure(failure, components), to: RunPreparation
  @doc false
  defdelegate validate_entry(bundle, entry), to: RunPreparation
  @doc false
  defdelegate validate_entry_missions(bundle, entry, missions), to: RunPreparation
  @doc false
  defdelegate validate_mission_capabilities(missions, bundles), to: RunPreparation
  defdelegate validation_result(prepared), to: RunPreparation

  @doc false
  @spec execute(PreparedRun.t(), PublicationAuthority.t()) ::
          {:ok, ExecutionOutcome.t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :provider_session_required
             | term()}
  def execute(%PreparedRun{} = prepared, authority), do: execute(prepared, authority, nil)
  def execute(_prepared, _authority), do: {:error, :invalid_prepared_run}

  @doc false
  @spec execute(PreparedRun.t(), PublicationAuthority.t(), Progress.sink() | nil) ::
          {:ok, ExecutionOutcome.t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :provider_session_required
             | term()}
  def execute(%PreparedRun{} = prepared, authority, progress_sink),
    do: open_free(prepared, authority, :run, progress_sink)

  def execute(_prepared, _authority, _progress_sink), do: {:error, :invalid_prepared_run}

  defp open_free(prepared, authority, operation, progress_sink) do
    cond do
      not PreparedRun.valid?(prepared) ->
        {:error, :invalid_prepared_run}

      not PublicationAuthority.authorized?(authority) ->
        {:error, :invalid_publication_authority}

      prepared.provider_declarations != [] ->
        {:error, :provider_session_required}

      true ->
        with {:ok, owner} <-
               ExecutionSessionOwner.start(
                 prepared,
                 authority,
                 self(),
                 nil,
                 nil,
                 operation,
                 progress_sink
               ),
             do: ExecutionSessionOwner.await(owner)
    end
  end

  @doc false
  @spec execute(
          PreparedRun.t(),
          PublicationAuthority.t(),
          ProviderExecution.t(),
          (binary() -> term()) | nil
        ) ::
          {:ok, ExecutionOutcome.t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :invalid_provider_execution
             | term()}
  def execute(%PreparedRun{} = prepared, authority, provider_execution, notifier)
      when is_nil(notifier) or is_function(notifier, 1),
      do: execute(prepared, authority, provider_execution, notifier, nil)

  def execute(_prepared, _authority, _provider_execution, _notifier),
    do: {:error, :invalid_prepared_run}

  @doc false
  @spec execute(
          PreparedRun.t(),
          PublicationAuthority.t(),
          ProviderExecution.t(),
          (binary() -> term()) | nil,
          Progress.sink() | nil
        ) ::
          {:ok, ExecutionOutcome.t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :invalid_provider_execution
             | term()}
  def execute(%PreparedRun{} = prepared, authority, provider_execution, notifier, progress_sink)
      when is_nil(notifier) or is_function(notifier, 1),
      do: open_active(prepared, authority, provider_execution, notifier, :run, progress_sink)

  def execute(_prepared, _authority, _provider_execution, _notifier, _progress_sink),
    do: {:error, :invalid_prepared_run}

  # Internal only, like its `execute/4` neighbour.
  # `PtcRunner.Kernel.CommandEngine` dispatches `doctor --connect` through it.
  # Connectivity answers for selected occurrences, so unlike a run it has no
  # provider-free form: a preparation selecting no provider is refused here, and
  # the command answers for it without opening an operation at all.
  #
  # It takes no authorization notifier and refuses an execution carrying
  # authorization targets, because a connectivity check must never open an interactive
  # authorization or ask a human for anything. The refusal is deliberate rather
  # than a silent downgrade to the non-interactive path: a caller that asked for
  # authorization and got a connectivity check that skipped it would be told the wrong thing.
  @doc false
  @spec connect(PreparedRun.t(), PublicationAuthority.t(), ProviderExecution.t()) ::
          {:ok, ConnectivityResult.t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :invalid_provider_execution
             | term()}
  def connect(%PreparedRun{} = prepared, authority, provider_execution),
    do: open_active(prepared, authority, provider_execution, nil, :connect, nil)

  def connect(_prepared, _authority, _provider_execution),
    do: {:error, :invalid_prepared_run}

  defp open_active(prepared, authority, provider_execution, notifier, operation, progress_sink) do
    cond do
      not PreparedRun.valid?(prepared) ->
        {:error, :invalid_prepared_run}

      not PublicationAuthority.authorized?(authority) ->
        {:error, :invalid_publication_authority}

      prepared.provider_declarations == [] ->
        {:error, :invalid_provider_execution}

      not ProviderExecution.bound_to_prepared?(provider_execution, prepared) ->
        {:error, :invalid_provider_execution}

      true ->
        with {:ok, owner} <-
               ExecutionSessionOwner.start(
                 prepared,
                 authority,
                 self(),
                 provider_execution,
                 notifier,
                 operation,
                 progress_sink
               ),
             do: ExecutionSessionOwner.await(owner)
    end
  end
end
