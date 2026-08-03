defmodule PtcRunner.Kernel.ProviderScopeOwner do
  @moduledoc false

  @startup_timeout_ms 1_000
  @request_timeout_ms 5_000
  @mutation_reserve_ms 50
  @forced_shutdown_reserve_ms 50
  @delayed_observation_timeout_ms 5_000
  @max_roots 64

  @type handle :: {pid(), pid(), pid()}

  @doc false
  @spec max_roots() :: pos_integer()
  def max_roots, do: @max_roots

  @spec start(pid(), pos_integer()) ::
          {:ok, handle()} | {:error, :provider_scope_unavailable}
  def start(session, cleanup_timeout_ms)
      when is_pid(session) and is_integer(cleanup_timeout_ms) and cleanup_timeout_ms > 0 do
    caller = self()
    ready_ref = make_ref()

    try do
      {controller, monitor} =
        spawn_monitor(fn ->
          controller = self()
          reaper_ready_ref = make_ref()

          reaper =
            spawn(fn ->
              start_reaper(controller, session, cleanup_timeout_ms, reaper_ready_ref)
            end)

          receive do
            {^reaper_ready_ref, ^reaper, signal_owner} ->
              send(caller, {ready_ref, self(), signal_owner, reaper})
              controller_loop(session, reaper, Process.monitor(reaper))
          after
            @startup_timeout_ms ->
              Process.exit(reaper, :kill)
              exit(:provider_scope_unavailable)
          end
        end)

      await_start(controller, monitor, ready_ref)
    catch
      :error, _reason -> {:error, :provider_scope_unavailable}
    end
  end

  @spec register(pid(), pid(), pid(), pid(), reference(), integer()) :: :ok
  def register(controller, session, root, reply_to, request_ref, deadline_ms)
      when is_pid(controller) and is_pid(session) and is_pid(root) and is_pid(reply_to) and
             is_reference(request_ref) and is_integer(deadline_ms) do
    send(
      controller,
      {__MODULE__, {:register, session, root, deadline_ms}, reply_to, request_ref}
    )

    :ok
  end

  @spec handoff(pid(), pid(), pid()) :: :ok | {:error, :provider_scope_unavailable}
  def handoff(cleanup_owner, session, root)
      when is_pid(cleanup_owner) and is_pid(session) and is_pid(root) do
    handoff(cleanup_owner, session, root, @request_timeout_ms)
  end

  @doc false
  @spec handoff(pid(), pid(), pid(), pos_integer()) ::
          :ok | {:error, :provider_scope_unavailable}
  def handoff(cleanup_owner, session, root, timeout_ms)
      when is_pid(cleanup_owner) and is_pid(session) and is_pid(root) and
             is_integer(timeout_ms) and timeout_ms > 0 do
    request(
      cleanup_owner,
      {:handoff, session, root, mutation_deadline(timeout_ms)},
      timeout_ms
    )
  end

  @spec stop(pid() | nil, pid() | nil, pid() | nil, non_neg_integer()) ::
          :ok | {:error, :provider_cleanup_failed}
  def stop(nil, _reaper, _session, _timeout_ms), do: :ok

  def stop(controller, reaper, session, timeout_ms)
      when is_pid(controller) and is_pid(reaper) and is_pid(session) and
             is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    case request(reaper, {:stop, session, deadline_ms}, timeout_ms) do
      :ok ->
        :ok

      _failure ->
        Process.exit(controller, :kill)
        {:error, :provider_cleanup_failed}
    end
  end

  defp start_reaper(controller, session, cleanup_timeout_ms, ready_ref) do
    reaper = self()
    signal_owner = spawn(fn -> await_reaper(reaper) end)
    send(controller, {ready_ref, self(), signal_owner})

    reaper_loop(
      controller,
      Process.monitor(controller),
      session,
      Process.monitor(session),
      signal_owner,
      cleanup_timeout_ms,
      %{}
    )
  end

  defp await_reaper(reaper) do
    reaper_ref = Process.monitor(reaper)

    receive do
      {__MODULE__, :stop, ^reaper} -> :ok
      {:DOWN, ^reaper_ref, :process, ^reaper, _reason} -> :ok
    end
  end

  defp controller_loop(session, reaper, reaper_ref) do
    receive do
      {__MODULE__, {:register, ^session, root, deadline_ms}, caller, request_ref}
      when is_pid(root) and node(root) == node() and is_integer(deadline_ms) ->
        send(
          reaper,
          {__MODULE__, {:register, session, root, deadline_ms}, self(), caller, request_ref}
        )

        controller_loop(session, reaper, reaper_ref)

      {:DOWN, ^reaper_ref, :process, ^reaper, _reason} ->
        :ok

      _message ->
        controller_loop(session, reaper, reaper_ref)
    end
  end

  defp reaper_loop(
         controller,
         controller_ref,
         session,
         session_ref,
         signal_owner,
         cleanup_timeout_ms,
         roots
       ) do
    receive do
      {__MODULE__, {:stop, ^session, deadline_ms}, caller, request_ref}
      when is_pid(caller) and is_integer(deadline_ms) ->
        cleanup_and_stop(
          controller,
          session,
          signal_owner,
          roots,
          deadline_ms,
          {caller, request_ref}
        )

      {:DOWN, ^session_ref, :process, ^session, _reason} ->
        deadline_ms = System.monotonic_time(:millisecond) + cleanup_timeout_ms
        cleanup_and_stop(controller, session, signal_owner, roots, deadline_ms, nil)

      {:DOWN, ^controller_ref, :process, ^controller, _reason} ->
        deadline_ms = System.monotonic_time(:millisecond) + cleanup_timeout_ms
        cleanup_and_stop(controller, session, signal_owner, roots, deadline_ms, nil)
    after
      0 ->
        reaper_wait(
          controller,
          controller_ref,
          session,
          session_ref,
          signal_owner,
          cleanup_timeout_ms,
          roots
        )
    end
  end

  defp reaper_wait(
         controller,
         controller_ref,
         session,
         session_ref,
         signal_owner,
         cleanup_timeout_ms,
         roots
       ) do
    receive do
      {__MODULE__, {:register, ^session, root, deadline_ms}, ^controller, caller, request_ref}
      when is_pid(caller) and is_pid(root) and node(root) == node() and
             is_integer(deadline_ms) ->
        {result, roots} =
          if before_deadline?(deadline_ms) do
            put_root(roots, root)
          else
            {{:error, :provider_scope_unavailable}, roots}
          end

        send(caller, {__MODULE__, :registration_result, request_ref, result})

        reaper_loop(
          controller,
          controller_ref,
          session,
          session_ref,
          signal_owner,
          cleanup_timeout_ms,
          roots
        )

      {__MODULE__, {:handoff, ^session, root, deadline_ms}, caller, request_ref}
      when is_pid(caller) and is_pid(root) and node(root) == node() and
             is_integer(deadline_ms) ->
        {result, roots} =
          if before_deadline?(deadline_ms) do
            drop_root(roots, root)
          else
            {{:error, :provider_scope_unavailable}, roots}
          end

        send(caller, {request_ref, result})

        reaper_loop(
          controller,
          controller_ref,
          session,
          session_ref,
          signal_owner,
          cleanup_timeout_ms,
          roots
        )

      {__MODULE__, {:stop, ^session, deadline_ms}, caller, request_ref}
      when is_pid(caller) and is_integer(deadline_ms) ->
        cleanup_and_stop(
          controller,
          session,
          signal_owner,
          roots,
          deadline_ms,
          {caller, request_ref}
        )

      {:DOWN, ^session_ref, :process, ^session, _reason} ->
        deadline_ms = System.monotonic_time(:millisecond) + cleanup_timeout_ms
        cleanup_and_stop(controller, session, signal_owner, roots, deadline_ms, nil)

      {:DOWN, ^controller_ref, :process, ^controller, _reason} ->
        deadline_ms = System.monotonic_time(:millisecond) + cleanup_timeout_ms
        cleanup_and_stop(controller, session, signal_owner, roots, deadline_ms, nil)

      {:DOWN, monitor, :process, _root, _reason} when is_map_key(roots, monitor) ->
        reaper_loop(
          controller,
          controller_ref,
          session,
          session_ref,
          signal_owner,
          cleanup_timeout_ms,
          Map.delete(roots, monitor)
        )

      _message ->
        reaper_loop(
          controller,
          controller_ref,
          session,
          session_ref,
          signal_owner,
          cleanup_timeout_ms,
          roots
        )
    end
  end

  defp cleanup_and_stop(controller, session, signal_owner, roots, deadline_ms, reply) do
    {result, delayed} = cleanup(controller, session, signal_owner, roots, deadline_ms)
    if reply, do: send(elem(reply, 0), {elem(reply, 1), result})

    observe_delayed(
      session,
      delayed,
      System.monotonic_time(:millisecond) + @delayed_observation_timeout_ms
    )
  end

  defp cleanup(controller, session, signal_owner, roots, deadline_ms) do
    remaining_ms = remaining(deadline_ms)
    reserve_ms = min(div(remaining_ms, 2), @forced_shutdown_reserve_ms)
    cooperative_deadline_ms = deadline_ms - reserve_ms
    signal_monitor = Process.monitor(signal_owner)

    send(signal_owner, {__MODULE__, :stop, self()})

    {survivors, signal_survivor} =
      await_survivors(
        controller,
        session,
        roots,
        {signal_monitor, signal_owner},
        cooperative_deadline_ms
      )

    Process.exit(controller, :kill)
    survivors = include_signal_survivor(survivors, signal_survivor)

    if map_size(survivors) == 0 do
      {:ok, %{}}
    else
      Enum.each(survivors, fn {_monitor, root} -> Process.exit(root, :kill) end)
      delayed = await_termination(session, survivors, deadline_ms)
      {{:error, :provider_cleanup_failed}, delayed}
    end
  end

  defp await_start(controller, monitor, ready_ref) do
    receive do
      {^ready_ref, ^controller, signal_owner, reaper} ->
        Process.demonitor(monitor, [:flush])
        {:ok, {controller, signal_owner, reaper}}

      {:DOWN, ^monitor, :process, ^controller, _reason} ->
        {:error, :provider_scope_unavailable}
    after
      @startup_timeout_ms ->
        Process.exit(controller, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :provider_scope_unavailable}
    end
  end

  defp request(owner, operation, timeout_ms) do
    monitor = Process.monitor(owner)
    request_ref = make_ref()
    send(owner, {__MODULE__, operation, self(), request_ref})

    receive do
      {^request_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        {:error, :provider_scope_unavailable}
    after
      timeout_ms ->
        Process.demonitor(monitor, [:flush])
        {:error, :provider_scope_unavailable}
    end
  end

  defp put_root(roots, root) do
    cond do
      root in Map.values(roots) ->
        {:ok, roots}

      map_size(roots) >= @max_roots ->
        {{:error, :provider_scope_unavailable}, roots}

      true ->
        {:ok, Map.put(roots, Process.monitor(root), root)}
    end
  end

  defp drop_root(roots, root) do
    case Enum.find(roots, fn {_monitor, registered} -> registered == root end) do
      {monitor, ^root} ->
        Process.demonitor(monitor, [:flush])
        {:ok, Map.delete(roots, monitor)}

      nil ->
        {{:error, :provider_scope_unavailable}, roots}
    end
  end

  defp await_survivors(_controller, _session, roots, nil, _deadline_ms)
       when map_size(roots) == 0,
       do: {%{}, nil}

  defp await_survivors(controller, session, roots, signal_survivor, deadline_ms) do
    if before_deadline?(deadline_ms) do
      receive do
        {__MODULE__, {:handoff, ^session, root, operation_deadline_ms}, caller, request_ref}
        when is_pid(caller) and is_pid(root) and node(root) == node() and
               is_integer(operation_deadline_ms) ->
          {result, roots} =
            if before_deadline?(operation_deadline_ms) do
              drop_root(roots, root)
            else
              {{:error, :provider_scope_unavailable}, roots}
            end

          send(caller, {request_ref, result})
          await_survivors(controller, session, roots, signal_survivor, deadline_ms)

        {__MODULE__, {:register, ^session, _root, _operation_deadline_ms}, ^controller, caller,
         request_ref}
        when is_pid(caller) ->
          send(
            caller,
            {__MODULE__, :registration_result, request_ref, {:error, :provider_scope_unavailable}}
          )

          await_survivors(controller, session, roots, signal_survivor, deadline_ms)

        {:DOWN, monitor, :process, _root, _reason} when is_map_key(roots, monitor) ->
          await_survivors(
            controller,
            session,
            Map.delete(roots, monitor),
            signal_survivor,
            deadline_ms
          )

        {:DOWN, signal_monitor, :process, signal_owner, _reason}
        when signal_survivor == {signal_monitor, signal_owner} ->
          await_survivors(controller, session, roots, nil, deadline_ms)
      after
        remaining(deadline_ms) -> {roots, signal_survivor}
      end
    else
      {roots, signal_survivor}
    end
  end

  defp await_termination(_session, roots, _deadline_ms) when map_size(roots) == 0, do: %{}

  defp await_termination(session, roots, deadline_ms) do
    if before_deadline?(deadline_ms) do
      receive do
        {__MODULE__, {:handoff, ^session, _root, _operation_deadline_ms}, caller, request_ref}
        when is_pid(caller) ->
          send(caller, {request_ref, {:error, :provider_scope_unavailable}})
          await_termination(session, roots, deadline_ms)

        {:DOWN, monitor, :process, _root, _reason} when is_map_key(roots, monitor) ->
          await_termination(session, Map.delete(roots, monitor), deadline_ms)
      after
        remaining(deadline_ms) -> roots
      end
    else
      roots
    end
  end

  defp observe_delayed(_session, roots, _deadline_ms) when map_size(roots) == 0, do: :ok

  defp observe_delayed(session, roots, deadline_ms) do
    if before_deadline?(deadline_ms) do
      receive do
        {__MODULE__, {:handoff, ^session, _root, _operation_deadline_ms}, caller, request_ref}
        when is_pid(caller) ->
          send(caller, {request_ref, {:error, :provider_scope_unavailable}})
          observe_delayed(session, roots, deadline_ms)

        {:DOWN, monitor, :process, _root, _reason} when is_map_key(roots, monitor) ->
          observe_delayed(session, Map.delete(roots, monitor), deadline_ms)
      after
        remaining(deadline_ms) -> :ok
      end
    else
      :ok
    end
  end

  defp include_signal_survivor(roots, nil), do: roots

  defp include_signal_survivor(roots, {monitor, signal_owner}),
    do: Map.put(roots, monitor, signal_owner)

  defp mutation_deadline(timeout_ms) do
    System.monotonic_time(:millisecond) + max(timeout_ms - @mutation_reserve_ms, 0)
  end

  defp before_deadline?(deadline_ms),
    do: System.monotonic_time(:millisecond) < deadline_ms

  defp remaining(deadline_ms),
    do: max(deadline_ms - System.monotonic_time(:millisecond), 0)
end
