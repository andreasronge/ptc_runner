defmodule PtcViewer.ReplConnection do
  @moduledoc false

  alias PtcViewer.ReplAdapter

  @connect_timeout_ms 5_000

  defstruct [:pid, :ref, :backend, :features]

  def start(adapter, config) do
    caller = self()

    {pid, ref} =
      spawn_monitor(fn ->
        owner_ref = Process.monitor(caller)
        result = connect(adapter, config)
        send(caller, {:repl_connection, self(), result})

        if match?({:ok, _backend, _features}, result) do
          await_stop(caller, owner_ref)
        else
          exit(:shutdown)
        end
      end)

    receive do
      {:repl_connection, ^pid, {:ok, backend, features}} ->
        {:ok, %__MODULE__{pid: pid, ref: ref, backend: backend, features: features}}

      {:repl_connection, ^pid, {:error, reason}} ->
        await_down(pid, ref)
        {:error, reason}

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        {:error, :repl_connection_failed}
    after
      @connect_timeout_ms ->
        Process.exit(pid, :kill)
        await_down(pid, ref)
        {:error, :repl_connection_failed}
    end
  end

  def stop(%__MODULE__{pid: pid, ref: ref}) do
    send(pid, :stop)
    await_down(pid, ref)
  end

  def attach_child(%__MODULE__{pid: pid}, child) when is_pid(child) do
    send(pid, {:attach_child, child})
    :ok
  end

  defp connect(adapter, config) do
    case apply(adapter, :connect, [config]) do
      {:ok, backend, features} ->
        case ReplAdapter.validate_features(features) do
          {:ok, safe_features} -> {:ok, backend, safe_features}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _invalid ->
        {:error, :repl_connection_failed}
    end
  rescue
    _exception -> {:error, :repl_connection_failed}
  catch
    _kind, _reason -> {:error, :repl_connection_failed}
  end

  defp await_stop(owner, owner_ref, children \\ []) do
    receive do
      {:attach_child, child} when is_pid(child) ->
        await_stop(owner, owner_ref, [child | children])

      :stop ->
        exit(:shutdown)

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        Enum.each(children, &stop_child/1)
        exit(:shutdown)
    end
  end

  defp stop_child(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  defp await_down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        end
    end
  end
end
