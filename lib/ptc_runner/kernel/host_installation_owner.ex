defmodule PtcRunner.Kernel.HostInstallationOwner do
  @moduledoc false

  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostCredentialLease
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.HostInstallationAuthority
  alias PtcRunner.Kernel.ProviderCallbackBoundary

  @authority_marker {__MODULE__, :authority}
  @operation_timeout_ms 1_000
  @reply_timeout_ms 1_100

  @spec start(HostConfig.t()) ::
          {:ok, HostInstallationAuthority.t()} | {:error, term()}
  def start(%HostConfig{} = host) do
    creator = self()
    token = make_ref()
    fence = :atomics.new(1, signed: true)
    :ok = :atomics.put(fence, 1, 1)

    case GenServer.start(__MODULE__, {host, creator, token, fence}) do
      {:ok, pid} ->
        case HostCredentialLease.start(pid) do
          {:ok, lease_owner, lease_fence, lease_table} ->
            build_authority(pid, token, fence, lease_owner, lease_fence, lease_table)

          {:error, _reason} = error ->
            stop(pid, token, :catalog, fence)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec invoke(pid(), reference(), atom(), :atomics.atomics_ref(), term()) :: term()
  def invoke(owner, token, role, fence, request)
      when is_pid(owner) and is_reference(token) and role in [:catalog, :registry] and
             is_reference(fence),
      do: GenServer.call(owner, {:invoke, token, role, fence, request}, :infinity)

  def invoke(_owner, _token, _role, _fence, _request),
    do: {:error, :invalid_host_installation}

  @spec authenticated?(pid(), reference()) :: boolean()
  def authenticated?(owner, token) when is_pid(owner) and is_reference(token) do
    Process.alive?(owner) and GenServer.call(owner, {:authenticate, token}, 1_000) == true
  catch
    :exit, _reason -> false
  end

  def authenticated?(_owner, _token), do: false

  @spec transfer(pid(), reference(), atom(), atom(), pid(), pos_integer()) ::
          :ok | {:error, atom()}
  def transfer(owner, token, from_role, to_role, new_owner, transition)
      when is_pid(owner) and is_reference(token) and is_pid(new_owner) and
             is_integer(transition) and transition > 0 do
    deadline = System.monotonic_time(:millisecond) + @operation_timeout_ms

    GenServer.call(
      owner,
      {:transfer, token, from_role, to_role, new_owner, transition, deadline},
      @reply_timeout_ms
    )
  catch
    :exit, _reason -> {:error, :invalid_host_installation_authority}
  end

  def transfer(_owner, _token, _from_role, _to_role, _new_owner, _transition),
    do: {:error, :invalid_host_installation_authority}

  @spec stop(pid(), reference(), atom(), :atomics.atomics_ref()) :: :ok
  def stop(owner, token, role, fence)
      when is_pid(owner) and is_reference(token) and is_reference(fence) do
    monitor = Process.monitor(owner)

    result =
      if Process.alive?(owner) do
        try do
          GenServer.call(owner, {:stop, token, role}, 1_000)
        catch
          :exit, _reason ->
            force_stop(owner, token, role, fence)
        end
      else
        :ok
      end

    case result do
      :ok ->
        await_stop(owner, monitor, token, role, fence)

      {:error, :stale_authority} ->
        Process.demonitor(monitor, [:flush])
        :ok
    end
  end

  def stop(_owner, _token, _role, _fence), do: :ok

  defp force_stop(owner, token, role, fence) do
    cond do
      not Process.alive?(owner) ->
        :ok

      current_authority?(owner, token, role, fence) ->
        Process.exit(owner, :kill)
        :ok

      true ->
        {:error, :stale_authority}
    end
  end

  defp await_stop(owner, monitor, token, role, fence) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
    after
      1_000 ->
        case force_stop(owner, token, role, fence) do
          :ok ->
            receive do
              {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
            end

          {:error, :stale_authority} ->
            Process.demonitor(monitor, [:flush])
            :ok
        end
    end
  end

  defp current_authority?(owner, token, role, fence) do
    authority_token(owner) == token and current_role?(fence, role)
  end

  defp current_role?(fence, :catalog), do: :atomics.get(fence, 1) == 1
  defp current_role?(fence, :registry), do: :atomics.get(fence, 1) < 0
  defp current_role?(_fence, _role), do: false

  defp authority_token(owner), do: authority_marker(owner)

  defp authority_marker(owner) do
    case Process.info(owner, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, @authority_marker, 0) do
          {@authority_marker, marker} -> marker
          nil -> nil
        end

      nil ->
        nil
    end
  end

  @impl GenServer
  def init({%HostConfig{} = host, creator, token, fence}) do
    Process.put(@authority_marker, token)
    monitor = Process.monitor(creator)

    {:ok,
     %{
       host: host,
       owner: creator,
       owner_monitor: monitor,
       role: :catalog,
       token: token,
       fence: fence,
       oauth_runtimes: %{},
       oauth_runtimes_installed?: false,
       preflights: %{}
     }}
  end

  @impl GenServer
  def handle_call(
        {:invoke, token, :registry, fence, {:install_oauth_runtimes, runtimes}},
        _from,
        %{
          token: token,
          role: :registry,
          fence: fence,
          oauth_runtimes_installed?: false
        } = state
      )
      when is_map(runtimes) and not is_struct(runtimes) do
    if current_role?(fence, :registry) and valid_oauth_runtimes?(runtimes, state.host) do
      {:reply, :ok, %{state | oauth_runtimes: runtimes, oauth_runtimes_installed?: true}}
    else
      {:reply, {:error, :invalid_host_installation}, state}
    end
  end

  def handle_call(
        {:invoke, token, :registry, fence, {:oauth_authority_epoch, name}},
        _from,
        %{
          token: token,
          role: :registry,
          fence: fence,
          oauth_runtimes_installed?: true
        } = state
      )
      when is_binary(name) do
    result =
      if current_role?(fence, :registry) do
        case Map.get(state.oauth_runtimes, name) do
          %{authority_epoch: authority_epoch} -> {:ok, authority_epoch}
          _missing -> {:error, :authorization_context_required}
        end
      else
        {:error, :authorization_context_required}
      end

    {:reply, result, state}
  end

  def handle_call(
        {:invoke, token, role, fence, {operation, name, selection, context}},
        from,
        %{host: host, token: token, role: role, fence: fence} = state
      )
      when operation in [:prepare, :preflight] and is_binary(name) do
    if current_role?(fence, role) do
      request =
        {operation, name, selection, context, Map.get(state.oauth_runtimes, name)}

      case bounded_owner_call(host, request, operation, context, from) do
        {:ok, {:private_preflight, acquire}} when operation == :preflight ->
          store_preflight(state, acquire, callback_bounds(context))

        result ->
          {:reply, result, state}
      end
    else
      {:reply, {:error, :invalid_host_installation}, state}
    end
  end

  def handle_call(
        {:invoke, token, role, fence, {:acquire, ticket, credentials, services}},
        from,
        %{token: token, role: role, fence: fence} = state
      )
      when is_reference(ticket) and is_map(credentials) and is_map(services) do
    if current_role?(fence, role) do
      case Map.pop(state.preflights, ticket) do
        {nil, _preflights} ->
          {:reply, {:error, :invalid_provider_preflight}, state}

        {preflight, preflights} ->
          result = bounded_acquire(preflight, credentials, services, from)
          {:reply, result, %{state | preflights: preflights}}
      end
    else
      {:reply, {:error, :invalid_host_installation}, state}
    end
  end

  def handle_call(
        {:invoke, token, role, fence, {:cancel_preflight, ticket}},
        _from,
        %{token: token, role: role, fence: fence} = state
      )
      when is_reference(ticket) do
    if current_role?(fence, role) do
      {:reply, :ok, %{state | preflights: Map.delete(state.preflights, ticket)}}
    else
      {:reply, {:error, :invalid_host_installation}, state}
    end
  end

  def handle_call(
        {:invoke, token, role, fence, request},
        _from,
        %{host: host, token: token, role: role, fence: fence} = state
      ) do
    if current_role?(fence, role) do
      reply =
        try do
          HostInstallation.owner_call(host, request)
        rescue
          _exception -> {:error, :invalid_host_installation}
        catch
          _kind, _reason -> {:error, :invalid_host_installation}
        end

      {:reply, reply, state}
    else
      {:reply, {:error, :invalid_host_installation}, state}
    end
  end

  def handle_call({:invoke, _token, _role, _fence, _request}, _from, state),
    do: {:reply, {:error, :invalid_host_installation}, state}

  def handle_call({:authenticate, token}, _from, %{token: token} = state),
    do: {:reply, true, state}

  def handle_call({:authenticate, _token}, _from, state), do: {:reply, false, state}

  def handle_call(
        {:transfer, token, role, :registry, new_owner, transition, deadline},
        _from,
        %{token: token, role: role, fence: fence} = state
      ) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        _cancelled = :atomics.compare_exchange(fence, 1, transition, 1)
        {:reply, {:error, :invalid_host_installation_authority}, state}

      :atomics.compare_exchange(fence, 1, transition, -transition) == :ok ->
        Process.demonitor(state.owner_monitor, [:flush])
        monitor = Process.monitor(new_owner)
        {:reply, :ok, %{state | owner: new_owner, owner_monitor: monitor, role: :registry}}

      true ->
        {:reply, {:error, :invalid_host_installation_authority}, state}
    end
  end

  def handle_call(
        {:transfer, _token, _role, _next_role, _new_owner, _transition, _deadline},
        _from,
        state
      ),
      do: {:reply, {:error, :invalid_host_installation_authority}, state}

  def handle_call({:stop, token, role}, _from, %{token: token, role: role} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call({:stop, _token, _role}, _from, state),
    do: {:reply, {:error, :stale_authority}, state}

  @impl GenServer
  def handle_info(
        {:DOWN, monitor, :process, _creator, _reason},
        %{owner_monitor: monitor} = state
      ),
      do: {:stop, :normal, state}

  def handle_info({:"ETS-TRANSFER", _table, _from, :credential_leases}, state),
    do: {:noreply, state}

  defp safe_owner_call(host, request, operation) do
    HostInstallation.owner_call(host, request)
  rescue
    _exception -> operation_failure(operation)
  catch
    _kind, _reason -> operation_failure(operation)
  end

  defp operation_failure(:prepare), do: {:error, :provider_prepare_failed}
  defp operation_failure(:preflight), do: {:error, :provider_preflight_failed}

  defp bounded_owner_call(host, request, operation, context, from) do
    case callback_bounds(context) do
      nil ->
        safe_owner_call(host, request, operation)

      bounds ->
        run_bounded(fn -> safe_owner_call(host, request, operation) end, bounds, from)
    end
  end

  defp bounded_acquire(%{acquire: acquire, bounds: nil}, credentials, services, _from),
    do: invoke_acquire(acquire, credentials, services)

  defp bounded_acquire(%{acquire: acquire, bounds: bounds}, credentials, services, from) do
    run_bounded(fn -> invoke_acquire(acquire, credentials, services) end, bounds, from)
  end

  defp run_bounded(callback, %{deadline: deadline, max_heap_words: max_heap_words}, from) do
    result =
      case Deadline.remaining(deadline) do
        0 ->
          {:error, :timeout}

        timeout_ms ->
          BoundedWorker.run(callback,
            timeout_ms: timeout_ms,
            max_heap_words: max_heap_words,
            cancel_with_caller: true,
            cancel_with: elem(from, 0)
          )
      end

    case result do
      {:ok, callback_result} -> callback_result
      {:error, reason} -> ProviderCallbackBoundary.nested_failure(reason)
    end
  end

  defp callback_bounds(%{deadline: deadline, limits: %{provider_heap_words: max_heap_words}})
       when is_integer(max_heap_words) and max_heap_words > 0 do
    if Deadline.valid?(deadline), do: %{deadline: deadline, max_heap_words: max_heap_words}
  end

  defp callback_bounds(_context), do: nil

  defp store_preflight(state, acquire, bounds) when is_function(acquire) do
    if map_size(state.preflights) < 128 do
      ticket = make_ref()

      preflight = %{acquire: acquire, bounds: bounds}

      {:reply, {:ok, ticket}, %{state | preflights: Map.put(state.preflights, ticket, preflight)}}
    else
      {:reply, {:error, :provider_preflight_failed}, state}
    end
  end

  defp store_preflight(state, _acquire, _bounds),
    do: {:reply, {:error, :invalid_provider_preflight}, state}

  defp invoke_acquire(acquire, credentials, services) do
    case :erlang.fun_info(acquire, :arity) do
      {:arity, 1} when map_size(services) == 0 -> acquire.(credentials)
      {:arity, 2} -> acquire.(credentials, services)
      _invalid -> {:error, :invalid_provider_preflight}
    end
  rescue
    _exception -> {:error, :provider_acquisition_failed}
  catch
    _kind, _reason -> {:error, :provider_acquisition_failed}
  end

  defp valid_oauth_runtimes?(runtimes, host) do
    Enum.all?(runtimes, fn {name, runtime} ->
      is_binary(name) and Map.has_key?(host.install, name) and is_map(runtime) and
        not is_struct(runtime)
    end)
  end

  defp build_authority(pid, token, fence, lease_owner, lease_fence, lease_table) do
    case HostInstallationAuthority.new(
           pid,
           token,
           fence,
           lease_owner,
           lease_fence,
           lease_table
         ) do
      {:ok, authority} ->
        {:ok, authority}

      {:error, _reason} = error ->
        HostCredentialLease.close(lease_owner, lease_fence, lease_table)
        stop(pid, token, :catalog, fence)
        error
    end
  rescue
    exception ->
      HostCredentialLease.close(lease_owner, lease_fence, lease_table)
      stop(pid, token, :catalog, fence)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      HostCredentialLease.close(lease_owner, lease_fence, lease_table)
      stop(pid, token, :catalog, fence)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end
end
