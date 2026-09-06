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

  The lease belongs to the execution-session owner, not the request caller.
  Caller death triggers that owner's normal provider cleanup. Capacity is
  released only after cleanup has finished. An owner that dies without a
  cleanup acknowledgement, or reports cleanup failure, fences this admission
  owner: later runs return `{:error, :run_admission_unavailable}`. Other
  admitted runs may finish. The child spec never automatically restarts this
  capacity domain; the host must drain old work before replacing it. Active
  execution owners also monitor admission-owner death and abort their runs.

  This counts hosted workflows, not physical LLM requests. Per-run provider
  task limits still apply. Direct adapter calls and executions through other
  entry points bypass this owner; Finch capacity, aggregate physical-attempt
  admission, and rate limits remain separate host responsibilities.
  """
  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.PublicationAuthority

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
      GenServer.start_link(__MODULE__, opts[:max_concurrent_runs])
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
      ref = Process.monitor(ExecutionSessionOwner.pid(owner))
      result = ExecutionSessionOwner.await(owner)

      receive do
        {:DOWN, ^ref, :process, _, :normal} ->
          result

        {:DOWN, ^ref, :process, _, :run_admission_unavailable} ->
          {:error, :run_admission_unavailable}

        {:DOWN, ^ref, :process, _, _} ->
          {:error, :execution_session_unavailable}
      end
    end
  end

  defp do_execute(_, _, _, _), do: {:error, :invalid_run_admission}

  @doc "Returns counts and readiness without exposing requests or provider configuration."
  @spec snapshot(pid()) :: {:ok, snapshot()} | {:error, :run_admission_unavailable}
  def snapshot(host), do: call(host, :snapshot)

  @doc false
  @spec admit(pid()) :: :ok | {:error, atom()}
  def admit(host), do: call(host, :admit)

  @doc false
  @spec complete(pid(), boolean()) :: :ok | {:error, atom()}
  def complete(host, clean?), do: call(host, {:complete, clean?})

  @impl true
  def init(capacity), do: {:ok, %{capacity: capacity, owners: %{}, status: :ready}}

  @impl true
  def handle_call(:snapshot, _, state) do
    state = fence_dead_owners(state)

    {:reply,
     {:ok, %{capacity: state.capacity, in_use: map_size(state.owners), status: state.status}},
     state}
  end

  def handle_call(:admit, {owner, _}, state) do
    state = fence_dead_owners(state)

    cond do
      Map.has_key?(state.owners, owner) or not Process.alive?(owner) ->
        {:reply, {:error, :run_admission_unavailable}, state}

      state.status == :unavailable ->
        {:reply, {:error, :run_admission_unavailable}, state}

      map_size(state.owners) >= state.capacity ->
        {:reply, {:error, :run_capacity_exhausted}, state}

      true ->
        {:reply, :ok, %{state | owners: Map.put(state.owners, owner, Process.monitor(owner))}}
    end
  end

  def handle_call({:complete, clean?}, {owner, _}, state) when is_boolean(clean?) do
    case Map.pop(state.owners, owner) do
      {nil, _} ->
        {:reply, {:error, :run_admission_unavailable}, state}

      {ref, owners} ->
        Process.demonitor(ref, [:flush])

        {:reply, :ok,
         %{state | owners: owners, status: if(clean?, do: state.status, else: :unavailable)}}
    end
  end

  def handle_call(_, _, state), do: {:reply, {:error, :run_admission_unavailable}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _}, state) do
    if state.owners[owner] == ref,
      do: {:noreply, %{state | owners: Map.delete(state.owners, owner), status: :unavailable}},
      else: {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp fence_dead_owners(state) do
    if Enum.any?(state.owners, fn {pid, _} -> not Process.alive?(pid) end),
      do: %{state | status: :unavailable},
      else: state
  end

  defp call(host, request) when is_pid(host) do
    GenServer.call(host, request, :infinity)
  catch
    :exit, _ -> {:error, :run_admission_unavailable}
  end

  defp call(_, _), do: {:error, :run_admission_unavailable}
end
