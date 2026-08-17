defmodule PtcGateway.Server do
  @moduledoc false

  use Supervisor

  alias PtcGateway.Admission
  alias PtcGateway.Connection

  @spec start(keyword()) :: {:ok, pid()} | {:error, atom()}
  def start(opts) when is_list(opts) do
    case Keyword.get(opts, :max_in_flight, 8) do
      ceiling when is_integer(ceiling) and ceiling > 0 ->
        start_tree(Keyword.put(opts, :max_in_flight, ceiling))

      _invalid ->
        {:error, :invalid_gateway_config}
    end
  end

  def start(_opts), do: {:error, :invalid_gateway_config}

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    Process.exit(pid, :shutdown)
    :ok
  end

  def stop(_pid), do: :ok

  @impl Supervisor
  def init(opts) do
    children = [
      {Admission, ceiling: Keyword.fetch!(opts, :max_in_flight)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp start_tree(opts) do
    with {:ok, pid} <- Supervisor.start_link(__MODULE__, opts) do
      true = Process.unlink(pid)

      with {:ok, admission} <- admission_pid(pid),
           {:ok, _connection} <-
             Supervisor.start_child(pid, connection_spec(opts, admission)) do
        {:ok, pid}
      else
        {:error, {:already_started, _pid}} -> {:error, :gateway_start_failed}
        {:error, {:shutdown, _reason}} -> {:error, :invalid_gateway_config}
        {:error, _reason} -> {:error, :invalid_gateway_config}
      end
    else
      {:error, {:already_started, _pid}} -> {:error, :gateway_start_failed}
      {:error, {:shutdown, _reason}} -> {:error, :invalid_gateway_config}
      {:error, _reason} -> {:error, :invalid_gateway_config}
    end
  end

  defp admission_pid(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value({:error, :invalid_gateway_config}, fn
      {Admission, pid, _type, _modules} when is_pid(pid) -> {:ok, pid}
      _other -> nil
    end)
  end

  defp connection_spec(opts, admission) do
    %{
      id: Connection,
      start:
        {Connection, :start_link,
         [
           [
             tools: Keyword.get(opts, :tools, []),
             admission: admission,
             read: Keyword.get(opts, :read),
             write: Keyword.get(opts, :write)
           ]
         ]},
      restart: :temporary
    }
  end
end
