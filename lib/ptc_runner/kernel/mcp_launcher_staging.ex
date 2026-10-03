defmodule PtcRunner.Kernel.MCPLauncherStaging do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ResourceRegistrar

  @enforce_keys [:pid, :path]
  defstruct [:pid, :path]

  @type t :: %__MODULE__{pid: pid(), path: binary()}

  @spec start(pid(), pos_integer()) ::
          {:ok, t()} | {:error, :mcp_stdio_launcher_unavailable}
  def start(owner, lease_ms, registrar \\ nil)

  def start(owner, lease_ms, registrar)
      when is_pid(owner) and is_integer(lease_ms) and lease_ms > 0 do
    case GenServer.start(__MODULE__, {owner, lease_ms, registrar}) do
      {:ok, pid} ->
        case GenServer.call(pid, :path) do
          {:ok, path} -> {:ok, %__MODULE__{pid: pid, path: path}}
          {:error, _reason} -> {:error, :mcp_stdio_launcher_unavailable}
        end

      {:error, _reason} ->
        {:error, :mcp_stdio_launcher_unavailable}
    end
  catch
    :exit, _reason -> {:error, :mcp_stdio_launcher_unavailable}
  end

  @spec close(t(), timeout()) :: :ok | {:error, :mcp_stdio_launcher_unavailable}
  def close(%__MODULE__{pid: pid}, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    GenServer.call(pid, :close, timeout_ms)
  catch
    :exit, _reason -> {:error, :mcp_stdio_launcher_unavailable}
  end

  @impl GenServer
  def init({owner, lease_ms, registrar}) do
    timer = Process.send_after(self(), :lease_expired, lease_ms)
    owner_ref = Process.monitor(owner)

    with :ok <- ResourceRegistrar.register_root(registrar),
         {:ok, directory} <- create_directory(8) do
      {:ok,
       %{
         owner_ref: owner_ref,
         timer: timer,
         directory: directory,
         path: Path.join(directory, "launcher")
       }}
    else
      {:error, reason} ->
        Process.cancel_timer(timer)
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:path, _from, state), do: {:reply, {:ok, state.path}, state}

  def handle_call(:close, _from, state) do
    result = cleanup(state)
    {:stop, :normal, result, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    _ = cleanup(state)
    {:stop, :normal, state}
  end

  def handle_info(:lease_expired, state) do
    _ = cleanup(state)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp create_directory(attempts) do
    case PrivateDirectory.create_temp("ptc-runner-launcher-", attempts) do
      {:ok, directory} -> {:ok, directory}
      {:error, _reason} -> {:error, :mcp_stdio_launcher_unavailable}
    end
  end

  defp cleanup(state) do
    Process.cancel_timer(state.timer)
    file_result = File.rm(state.path)
    directory_result = File.rmdir(state.directory)

    if file_result in [:ok, {:error, :enoent}] and directory_result == :ok,
      do: :ok,
      else: {:error, :mcp_stdio_launcher_unavailable}
  end
end
