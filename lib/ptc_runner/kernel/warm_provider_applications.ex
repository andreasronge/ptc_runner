defmodule PtcRunner.Kernel.WarmProviderApplications do
  @moduledoc false

  @spec start([atom()], pos_integer()) ::
          {:ok, [atom()], pid() | nil} | {:error, atom(), [atom()]}
  def start([], _capacity), do: {:ok, [], nil}

  def start([:req_llm], capacity) do
    :global.trans({__MODULE__, self()}, fn -> start_req_llm(capacity) end)
  end

  def start(_, _), do: {:error, :provider_runtime_unsupported, []}

  defp start_req_llm(capacity) do
    if Enum.any?(Application.started_applications(), &(elem(&1, 0) == :req_llm)) do
      {:error, :provider_application_prestarted, []}
    else
      configure_and_start(capacity)
    end
  end

  defp configure_and_start(capacity) do
    protocols = Application.get_env(:req_llm, :stream_pool_protocols, [:http1])
    finch = Application.get_env(:req_llm, :finch, [])

    if protocols == [:http1] and finch == [] do
      Application.put_env(:req_llm, :load_dotenv, false)
      Application.put_env(:llm_db, :load_dotenv, false)
      Application.put_env(:req_llm, :stream_pool_protocols, [:http1])
      Application.put_env(:req_llm, :stream_pool_count, 1)
      Application.put_env(:req_llm, :stream_pool_size, capacity)

      case Application.ensure_all_started(:req_llm) do
        {:ok, applications} -> attest_started(applications, capacity)
        _ -> {:error, :provider_application_unavailable, []}
      end
    else
      {:error, :provider_connection_unverifiable, []}
    end
  end

  defp attest_started(applications, capacity) do
    pid = Process.whereis(ReqLLM.Finch.Supervisor)

    if is_pid(pid) and ready?(pid, capacity),
      do: {:ok, applications, pid},
      else: {:error, :provider_connection_unverifiable, applications}
  end

  @spec ready?(pid(), pos_integer()) :: boolean()
  def ready?(pid, capacity \\ 1) do
    Process.whereis(ReqLLM.Finch.Supervisor) == pid and Process.alive?(pid) and
      geometry?(capacity) and live_pools?(capacity)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp geometry?(capacity) do
    case Registry.meta(ReqLLM.Finch, :config) do
      {:ok,
       %{
         pools: pools,
         default_pool_config: %{mod: Finch.HTTP1.Pool, count: 1, size: size, conn_opts: conn_opts}
       }}
      when size >= capacity ->
        map_size(pools) == 0 and conn_opts[:protocols] == [:http1]

      _ ->
        false
    end
  end

  defp live_pools?(capacity) do
    Registry.select(
      ReqLLM.Finch.SupervisorRegistry,
      [{{:"$1", :"$2", :"$3"}, [], [{{:"$2", :"$3"}}]}]
    )
    |> Enum.all?(fn
      {supervisor, {Finch.HTTP1.Pool, 1, %{size: size, conn_opts: conn_opts}}}
      when size >= capacity ->
        conn_opts[:protocols] == [:http1] and one_live_shard?(supervisor)

      _ ->
        false
    end)
  end

  defp one_live_shard?(supervisor) do
    # Finch.set_pool_count/3 changes children without updating registry config.
    # Effective geometry therefore requires both configuration and live children.
    case Supervisor.which_children(supervisor) do
      [{_, pid, :worker, [Finch.HTTP1.Pool]}] when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end
end
