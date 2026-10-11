defmodule PtcRunner.Kernel.RunAdmission do
  @moduledoc """
  Explicit host-owned admission for concurrent one-shot executions.

  Start one owner under the embedding host's supervisor with
  `max_concurrent_runs: n`, and pass its PID to `execute/5` for every hosted
  run. Preparation and publication keep their existing Kernel contracts;
  execution returns the same sealed `PtcRunner.Kernel.ExecutionOutcome`.
  Provider execution must use host-owned applications and no interactive
  authorization. This module neither starts ReqLLM nor changes its pools.

  A full owner returns `{:error, :run_capacity_exhausted}` before consuming the
  preparation, claiming publication, or activating providers. There is no
  waiting queue for execution capacity. Inbound connections, preparation,
  provisional admission processes, and control mailboxes remain the host's
  responsibility to bound.

  `reserve/2` supports transport commitment before execution exists. An unused
  reservation holds only capacity, a caller monitor and a deadline timer; it
  creates no session, input, policy, sink, publication authority, execution
  identity or provider activity. The caller supplies those only to `activate/3`
  or `activate/5`. Caller death or `close/1` releases unused capacity.
  Absolute deadlines remain in force after activation and request cancellation
  without releasing capacity ahead of cleanup.

  After activation, the lease belongs to the execution-session owner.
  Caller death triggers that owner's normal provider cleanup. Capacity is
  released only after cleanup has finished. An owner that dies without a
  cleanup acknowledgement, or reports cleanup failure, fences this admission
  owner: later runs return `{:error, :run_admission_unavailable}`. Other
  admitted runs may finish. The child spec never automatically restarts this
  capacity domain; the host must drain old work before replacing it. Active
  execution owners also monitor admission-owner death and abort their runs.

  ServingTemplate retains a transferred reservation through calling-worker
  publication. Execution cleanup transfers its capacity back to the monitored
  caller, without making the slot available; only publication completion releases
  it. Unclean completion and unexpected execution-owner death also transfer a
  retained lease to the caller while fencing the domain; fenced snapshots keep
  counting that lease until caller cleanup finishes. Admission refusal during
  activation is distinct from request/deadline cancellation.
  Expiry marks it cancelled but retains it until publication cleanup. Caller
  death in this interval fences admission, as publication cleanup is unproven.

  This counts hosted workflows, not physical LLM requests. Per-run provider
  task limits still apply. Direct adapter calls and executions through other
  entry points bypass this owner; Finch capacity, aggregate physical-attempt
  admission, and rate limits remain separate host responsibilities.
  """

  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunAdmissionOwner

  @typedoc "Opaque single-use caller-owned capacity reservation."
  @opaque reservation :: {RunAdmissionOwner, pid(), reference()}
  @typedoc "Activated execution handle; only its caller may await it."
  @opaque execution :: {__MODULE__, pid(), ExecutionSessionOwner.t()}

  @doc """
  Reserves capacity atomically for the calling process, without execution resources.

  `deadline` is an absolute `System.monotonic_time(:millisecond)` integer
  or `:infinity`. An expired or invalid deadline returns
  `{:error, :run_admission_unavailable}`. A full domain returns
  `{:error, :run_capacity_exhausted}`; a dead or fenced domain returns
  `{:error, :run_admission_unavailable}`. No snapshot authorizes admission.
  """
  @spec reserve(pid(), integer() | :infinity) ::
          {:ok, reservation()} | {:error, :run_capacity_exhausted | :run_admission_unavailable}
  def reserve(host, deadline), do: call(host, {:reserve, deadline})

  @doc """
  Activates a provider-free reservation and returns an execution handle.

  Only the reserving caller can activate it, once. Transfer to a new execution
  owner happens before publication claim, preparation consumption, sink opening
  or dispatch. Failed activation closes the reservation; input validation errors
  retain their existing execution error codes. A closed, expired, foreign or
  already activated reservation returns `{:error, :run_admission_unavailable}`.
  Use `await/1` to collect the sealed outcome and wait for owner cleanup.
  """
  @spec activate(reservation(), PreparedRun.t(), PublicationAuthority.t()) ::
          {:ok, execution()} | {:error, term()}
  def activate(reservation, prepared, authority),
    do: activate_execution(reservation, prepared, authority, nil)

  @doc "Activates a reservation with a retained runtime borrow."
  @spec activate(
          reservation(),
          PreparedRun.t(),
          PublicationAuthority.t(),
          ProviderExecution.Retained.t()
        ) :: {:ok, execution()} | {:error, term()}
  def activate(reservation, prepared, authority, %ProviderExecution.Retained{} = retained),
    do: activate_execution(reservation, prepared, authority, retained)

  @doc "Activates with the preparation's bound catalog and host-owned provider services."
  @spec activate(
          reservation(),
          PreparedRun.t(),
          PublicationAuthority.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t()
        ) ::
          {:ok, execution()} | {:error, term()}
  def activate(
        reservation,
        prepared,
        authority,
        catalog,
        %ProviderRuntimeServices{provider_application_mode: :host_owned} = services
      ) do
    case ProviderExecution.new(catalog, services, []) do
      {:ok, execution} ->
        activate_execution(reservation, prepared, authority, execution)

      {:error, _} = error ->
        cancel(reservation)
        error
    end
  end

  def activate(reservation, _, _, _, _) do
    cancel(reservation)
    {:error, :invalid_provider_execution}
  end

  defp activate_execution(
         {RunAdmissionOwner, host, ref} = reservation,
         prepared,
         authority,
         execution
       ) do
    with {:ok, ticket} <- call(host, {:begin_activation, ref}) do
      case ExecutionSessionOwner.start_reserved(
             host,
             ref,
             ticket,
             prepared,
             authority,
             self(),
             execution
           ) do
        {:ok, owner} ->
          {:ok, {__MODULE__, self(), owner}}

        {:error, _} = error ->
          cancel(reservation)
          error
      end
    end
  end

  defp activate_execution(_, _, _, _), do: {:error, :run_admission_unavailable}

  @doc """
  Cancels or closes a reservation owned by the calling process.

  Use this after response commitment fails. Before transfer it releases the
  slot immediately. After transfer it requests execution-owner cancellation,
  retaining capacity until cleanup acknowledgement. Cancellation, expiry and
  caller death cannot release an active lease themselves. Repeated cancellation
  or use after completion returns `{:error, :run_admission_unavailable}`.
  Cancellation races with activation at the admission owner: cancellation
  before transfer prevents dispatch; after transfer execution may have begun.
  """
  @spec cancel(reservation()) :: :ok | {:error, :run_admission_unavailable}
  def cancel({RunAdmissionOwner, host, ref}), do: call(host, {:cancel, ref})
  def cancel(_), do: {:error, :run_admission_unavailable}

  @doc "Closes a reservation with the same ownership and cancellation semantics as cancel/1."
  @spec close(reservation()) :: :ok | {:error, :run_admission_unavailable}
  def close(reservation), do: cancel(reservation)

  @doc false
  @spec cancel_external(reservation()) :: :ok | {:error, :run_admission_unavailable}
  def cancel_external({RunAdmissionOwner, host, ref}), do: call(host, {:cancel_external, ref})
  def cancel_external(_), do: {:error, :run_admission_unavailable}

  @doc false
  def quiesce(host), do: call(host, :quiesce)

  @doc false
  def cancel_all(host), do: call(host, :cancel_all)

  @doc "Waits for the activated execution's sealed outcome and execution-owner cleanup."
  @spec await(execution()) :: {:ok, ExecutionOutcome.t()} | {:error, term()}
  def await({__MODULE__, caller, owner}) when caller == self(), do: await_execution(owner)
  def await(_), do: {:error, :execution_session_unavailable}

  @doc false
  @spec retain_publication(reservation()) :: :ok | {:error, atom()}
  def retain_publication({RunAdmissionOwner, host, ref}),
    do: call(host, {:retain_publication, ref})

  @doc false
  @spec finish_publication(reservation(), boolean()) :: :ok | {:error, atom()}
  def finish_publication({RunAdmissionOwner, host, ref}, clean?),
    do: call(host, {:finish_publication, ref, clean?})

  @doc "Atomically freezes the retained call's terminal admission state without releasing capacity."
  @spec freeze_publication(reservation(), boolean()) :: :ok | {:error, atom()}
  def freeze_publication({RunAdmissionOwner, host, ref}, clean?),
    do: call(host, {:freeze_publication, ref, clean?})

  @doc "Reports whether shutdown quiesced a previously healthy domain and all capacity is free."
  @spec shutdown_clean?(pid()) :: boolean()
  def shutdown_clean?(host), do: call(host, :shutdown_clean) == true

  @doc false
  def transfer(host, ref, ticket, caller), do: call(host, {:transfer, ref, ticket, caller})

  @type snapshot :: %{
          capacity: pos_integer(),
          in_use: non_neg_integer(),
          status: :ready | :unavailable
        }

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  @doc "Starts one admission domain; only `:max_concurrent_runs` is accepted."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) == [:max_concurrent_runs] and
         is_integer(opts[:max_concurrent_runs]) and opts[:max_concurrent_runs] > 0 do
      RunAdmissionOwner.start_link(opts[:max_concurrent_runs])
    else
      {:error, :invalid_run_admission}
    end
  end

  def start_link(_), do: {:error, :invalid_run_admission}

  @doc "Executes one provider-free preparation and waits for execution-owner cleanup."
  @spec execute(pid(), PreparedRun.t(), PublicationAuthority.t()) ::
          {:ok, ExecutionOutcome.t()} | {:error, term()}
  def execute(host, prepared, authority), do: do_execute(host, prepared, authority, nil)

  @doc "Executes one preparation using its bound catalog and host-owned runtime services."
  @spec execute(
          pid(),
          PreparedRun.t(),
          PublicationAuthority.t(),
          InstallationCatalog.t(),
          ProviderRuntimeServices.t()
        ) ::
          {:ok, ExecutionOutcome.t()} | {:error, term()}
  def execute(
        host,
        prepared,
        authority,
        catalog,
        %ProviderRuntimeServices{provider_application_mode: :host_owned} = services
      ) do
    with {:ok, execution} <- ProviderExecution.new(catalog, services, []) do
      do_execute(host, prepared, authority, execution)
    end
  end

  def execute(_, _, _, _, _), do: {:error, :invalid_provider_execution}

  defp do_execute(host, prepared, authority, execution) when is_pid(host) do
    with {:ok, owner} <-
           ExecutionSessionOwner.start_admitted(host, prepared, authority, self(), execution) do
      await_execution(owner)
    end
  end

  defp do_execute(_, _, _, _), do: {:error, :invalid_run_admission}

  # The owner monitor is taken before activation, so its exit reason survives
  # an owner that stops before `await/1`. Once that monitor has fired its
  # `:DOWN` is queued or was consumed by an earlier await of this handle.
  defp await_execution(owner) do
    pid = ExecutionSessionOwner.pid(owner)
    ref = ExecutionSessionOwner.monitor(owner)
    timeout = if monitoring?(pid), do: :infinity, else: 0
    result = ExecutionSessionOwner.await(owner)

    receive do
      {:DOWN, ^ref, :process, _, :normal} ->
        result

      {:DOWN, ^ref, :process, _, :run_admission_unavailable} ->
        {:error, :run_admission_unavailable}

      {:DOWN, ^ref, :process, _, _} ->
        {:error, :execution_session_unavailable}
    after
      timeout -> {:error, :execution_session_unavailable}
    end
  end

  defp monitoring?(pid) do
    {:monitors, monitors} = Process.info(self(), :monitors)
    {:process, pid} in monitors
  end

  @doc "Returns counts and readiness without exposing requests or provider configuration."
  @spec snapshot(pid()) :: {:ok, snapshot()} | {:error, :run_admission_unavailable}
  def snapshot(host), do: call(host, :snapshot)

  @doc false
  @spec admit(pid()) :: :ok | {:error, atom()}
  def admit(host), do: call(host, :admit)

  @doc false
  @spec complete(pid(), boolean()) :: :ok | {:error, atom()}
  def complete(host, clean?), do: call(host, {:complete, clean?})

  defp call(host, request), do: RunAdmissionOwner.call(host, request)
end
