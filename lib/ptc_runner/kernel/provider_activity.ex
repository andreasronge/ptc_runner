defmodule PtcRunner.Kernel.ProviderActivity do
  @moduledoc """
  Owner-backed monotonic provider-activity marker.

  A fresh marker belongs to its creating process, remains linked to it, may be
  claimed by exactly one prepared run, is consumed once, and admits at most one
  owned build. The marker also monitors its creator so even a normal owner exit
  closes it. Activity then changes monotonically from false to true. Every
  transition runs as one operation inside the owner process. Calls carry a
  server-checked monotonic deadline and allow a short reply grace, so they
  remain bounded without a timed-out queued transition later mutating the
  marker.
  """

  use GenServer

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.Deadline

  @operation_timeout_ms 5_000
  @reply_grace_ms 100

  @enforce_keys [:owner, :creator, :attestation]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type t :: %__MODULE__{owner: pid(), creator: pid(), attestation: binary()}

  @spec start_link() :: {:ok, t()} | {:error, term()}
  def start_link do
    creator = self()

    case GenServer.start_link(__MODULE__, creator) do
      {:ok, owner} ->
        activity = %__MODULE__{owner: owner, creator: creator, attestation: <<>>}
        {:ok, %{activity | attestation: Attestation.attest(__MODULE__, payload(activity))}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec start_owned((t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def start_owned(constructor) when is_function(constructor, 1) do
    with {:ok, activity} <- start_link() do
      try do
        case constructor.(activity) do
          {:ok, _value} = success ->
            success

          failure ->
            stop(activity)
            failure
        end
      rescue
        exception ->
          stop(activity)
          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          stop(activity)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  @doc false
  @spec claim(t()) :: :ok | {:error, :provider_activity_unavailable}
  def claim(%__MODULE__{} = activity),
    do: owned_call(activity, :claim)

  def claim(_activity), do: {:error, :provider_activity_unavailable}

  @doc false
  @spec consume(t()) :: :ok | {:error, :provider_activity_unavailable}
  def consume(%__MODULE__{} = activity),
    do: call_if_valid(activity, :consume, {:error, :provider_activity_unavailable})

  def consume(_activity), do: {:error, :provider_activity_unavailable}

  @doc false
  @spec authorize_executor(t(), pid()) :: :ok | {:error, :provider_activity_unavailable}
  def authorize_executor(%__MODULE__{} = activity, executor) when is_pid(executor),
    do:
      call_if_valid(
        activity,
        {:authorize_executor, executor},
        {:error, :provider_activity_unavailable}
      )

  def authorize_executor(_activity, _executor), do: {:error, :provider_activity_unavailable}

  @doc false
  @spec begin_build(t()) :: :ok | {:error, :provider_activity_unavailable}
  def begin_build(%__MODULE__{} = activity),
    do: call_if_valid(activity, :begin_build, {:error, :provider_activity_unavailable})

  def begin_build(_activity), do: {:error, :provider_activity_unavailable}

  @spec mark(t()) :: :ok | {:error, :provider_activity_unavailable}
  def mark(%__MODULE__{} = activity),
    do: call_if_valid(activity, :mark, {:error, :provider_activity_unavailable})

  def mark(_activity), do: {:error, :provider_activity_unavailable}

  @spec value(t()) :: boolean() | :unknown
  def value(%__MODULE__{} = activity) do
    if valid?(activity), do: call(activity.owner, :value, :unknown), else: :unknown
  end

  def value(_activity), do: :unknown

  @doc false
  @spec claimed?(t()) :: boolean()
  def claimed?(%__MODULE__{} = activity) do
    valid?(activity) and call(activity.owner, :claimed?, false)
  end

  def claimed?(_activity), do: false

  @doc false
  @spec consumed?(t()) :: boolean()
  def consumed?(%__MODULE__{} = activity) do
    valid?(activity) and call(activity.owner, :consumed?, false)
  end

  def consumed?(_activity), do: false

  @spec stop(t()) ::
          :ok | {:error, :not_owner | :provider_activity_unavailable}
  def stop(%__MODULE__{} = activity) do
    case stop_call(activity) do
      :ok -> :ok
      {:error, :provider_activity_unavailable} -> {:error, :not_owner}
      :owner_gone -> :ok
      :call_unavailable -> {:error, :provider_activity_unavailable}
    end
  end

  def stop(_activity), do: :ok

  @impl true
  def init(creator) when is_pid(creator) do
    monitor = Process.monitor(creator)

    {:ok,
     %{
       creator: creator,
       controller: creator,
       executor: creator,
       monitor: monitor,
       state: :unclaimed
     }}
  end

  @impl true
  def handle_call(
        {:deadline, operation, deadline},
        from,
        state
      )
      when is_atom(operation) or is_tuple(operation) do
    if Deadline.live?(deadline),
      do: handle_operation(operation, from, state),
      else: expired_operation(operation, from, state)
  end

  def handle_call(_operation, _from, state),
    do: {:reply, {:error, :provider_activity_unavailable}, state}

  defp handle_operation(
         :claim,
         {caller, _tag},
         %{creator: creator, state: :unclaimed} = state
       ) do
    case {caller == creator, creator_attached?(state)} do
      {true, true} ->
        transition(:claim, state)

      {true, false} ->
        unavailable_and_stop(state)

      {false, _attached?} ->
        {:reply, {:error, :provider_activity_unavailable}, state}
    end
  end

  defp handle_operation(:claim, _from, state),
    do: {:reply, {:error, :provider_activity_unavailable}, state}

  defp handle_operation(:consume, {caller, _tag}, %{state: :claimed} = state) do
    if creator_attached?(state),
      do: {:reply, :ok, transfer(state, caller, :consumed)},
      else: unavailable_and_stop(state)
  end

  defp handle_operation(:consume, _from, state),
    do: {:reply, {:error, :provider_activity_unavailable}, state}

  defp handle_operation(
         {:authorize_executor, executor},
         {controller, _tag},
         %{controller: controller, state: :consumed} = state
       )
       when is_pid(executor) do
    if controller_attached?(state) and Process.alive?(executor),
      do: {:reply, :ok, %{state | executor: executor}},
      else: unavailable_and_stop(state)
  end

  defp handle_operation({:authorize_executor, _executor}, _from, state),
    do: {:reply, {:error, :provider_activity_unavailable}, state}

  defp handle_operation(
         :begin_build,
         {caller, _tag},
         %{controller: caller, state: :consumed} = state
       ) do
    if controller_attached?(state),
      do: transition(:begin_build, state),
      else: unavailable_and_stop(state)
  end

  defp handle_operation(:begin_build, _from, state),
    do: {:reply, {:error, :provider_activity_unavailable}, state}

  defp handle_operation(:mark, {caller, _tag}, %{executor: caller} = state) do
    if controller_attached?(state),
      do: transition(:mark, state),
      else: unavailable_and_stop(state)
  end

  defp handle_operation(:mark, _from, state),
    do: {:reply, {:error, :provider_activity_unavailable}, state}

  defp handle_operation(:stop, {caller, _tag}, %{controller: caller} = state),
    do: {:stop, :normal, :ok, state}

  defp handle_operation(:stop, _from, state),
    do: {:reply, {:error, :provider_activity_unavailable}, state}

  defp handle_operation(:value, _from, state),
    do: {:reply, state.state == :active, state}

  defp handle_operation(:claimed?, _from, %{state: :claimed} = state) do
    if creator_attached?(state),
      do: {:reply, true, state},
      else: {:stop, :normal, false, state}
  end

  defp handle_operation(:claimed?, _from, state), do: {:reply, false, state}

  defp handle_operation(
         :consumed?,
         {caller, _tag},
         %{controller: controller, executor: executor, state: :consumed} = state
       ) do
    if caller in [controller, executor] and controller_attached?(state),
      do: {:reply, true, state},
      else: {:reply, false, state}
  end

  defp handle_operation(:consumed?, _from, state), do: {:reply, false, state}

  defp handle_operation(_operation, _from, state),
    do: {:reply, {:error, :provider_activity_unavailable}, state}

  defp expired_operation(operation, _from, state)
       when operation in [:claim, :consume, :begin_build, :mark],
       do: {:reply, {:error, :provider_activity_unavailable}, state}

  defp expired_operation(:value, _from, state), do: {:reply, :unknown, state}
  defp expired_operation(:claimed?, _from, state), do: {:reply, false, state}
  defp expired_operation(:consumed?, _from, state), do: {:reply, false, state}
  defp expired_operation(:stop, from, state), do: handle_operation(:stop, from, state)

  defp expired_operation(_operation, _from, state),
    do: {:reply, {:error, :provider_activity_unavailable}, state}

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, controller, _reason},
        %{
          monitor: monitor,
          controller: controller
        } = state
      ),
      do: {:stop, :normal, state}

  defp transition(:claim, %{state: :unclaimed} = state),
    do: {:reply, :ok, %{state | state: :claimed}}

  defp transition(:begin_build, %{state: :consumed} = state),
    do: {:reply, :ok, %{state | state: :built}}

  defp transition(:mark, state),
    do: {:reply, :ok, %{state | state: :active}}

  defp transition(_operation, state),
    do: {:reply, {:error, :provider_activity_unavailable}, state}

  defp owned_call(activity, operation) do
    if valid?(activity) and activity.creator == self(),
      do: call(activity.owner, operation, {:error, :provider_activity_unavailable}),
      else: {:error, :provider_activity_unavailable}
  end

  defp call_if_valid(activity, operation, fallback) do
    if valid?(activity),
      do: call(activity.owner, operation, fallback),
      else: fallback
  end

  defp transfer(%{creator: creator, monitor: monitor} = state, controller, next_state) do
    Process.demonitor(monitor, [:flush])

    if controller != creator do
      Process.unlink(creator)
      Process.link(controller)
    end

    %{
      state
      | controller: controller,
        executor: controller,
        monitor: Process.monitor(controller),
        state: next_state
    }
  end

  defp call(owner, operation, fallback) do
    deadline = Deadline.new(@operation_timeout_ms)
    reply_timeout_ms = Deadline.remaining(deadline) + @reply_grace_ms
    GenServer.call(owner, {:deadline, operation, deadline}, reply_timeout_ms)
  catch
    :exit, _reason -> fallback
  end

  defp stop_call(activity) do
    if valid?(activity) do
      deadline = Deadline.new(@operation_timeout_ms)
      reply_timeout_ms = Deadline.remaining(deadline) + @reply_grace_ms
      GenServer.call(activity.owner, {:deadline, :stop, deadline}, reply_timeout_ms)
    else
      :owner_gone
    end
  catch
    :exit, {:noproc, _call} -> :owner_gone
    :exit, {:normal, _call} -> :owner_gone
    :exit, _reason -> :call_unavailable
  end

  defp creator_attached?(%{creator: creator}) do
    attached?(creator)
  end

  defp controller_attached?(%{controller: controller}), do: attached?(controller)

  defp attached?(process) do
    Process.alive?(process) and
      case Process.info(self(), :links) do
        {:links, links} -> process in links
        nil -> false
      end
  end

  defp unavailable_and_stop(state),
    do: {:stop, :normal, {:error, :provider_activity_unavailable}, state}

  defp valid?(%__MODULE__{owner: owner, creator: creator, attestation: attestation} = activity),
    do:
      Enum.sort(Map.keys(activity)) == @field_keys and is_pid(owner) and is_pid(creator) and
        Attestation.valid?(__MODULE__, payload(activity), attestation)

  defp payload(activity), do: {activity.owner, activity.creator}
end
