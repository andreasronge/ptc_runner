defmodule PtcGateway.HTTP.Server do
  @moduledoc false

  use Supervisor

  alias PtcGateway.Admission
  alias PtcGateway.Catalog
  alias PtcGateway.HTTP.Bind
  alias PtcGateway.HTTP.Router
  alias PtcGateway.HTTP.Secret

  @loopback {127, 0, 0, 1}
  @wildcard {0, 0, 0, 0}
  @addresses [@loopback, @wildcard]

  @spec start(keyword()) :: {:ok, pid()} | {:error, atom()}
  def start(opts) when is_list(opts) do
    with {:ok, params} <- params(opts) do
      start_tree(params)
    end
  end

  def start(_opts), do: {:error, :invalid_gateway_config}

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :shutdown)
    :ok
  end

  def stop(_pid), do: :ok

  @spec listener_info(pid()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, atom()}
  def listener_info(pid) when is_pid(pid) do
    with {:ok, bandit} <- bandit_pid(pid) do
      ThousandIsland.listener_info(bandit)
    end
  end

  def listener_info(_pid), do: {:error, :invalid_gateway_config}

  @impl Supervisor
  def init(params) do
    children = [
      {Admission, ceiling: params.max_in_flight},
      {Bind, host: params.host, port: params.port},
      Secret
    ]

    Supervisor.init(children, strategy: :rest_for_one, auto_shutdown: :any_significant)
  end

  defp start_tree(params) do
    {token, supervisor_params} = Map.pop!(params, :token)

    with {:ok, pid} <- Supervisor.start_link(__MODULE__, supervisor_params) do
      true = Process.unlink(pid)

      case start_bandit(pid, supervisor_params, token) do
        {:ok, _bandit} ->
          {:ok, pid}

        {:error, reason} ->
          stop(pid)
          {:error, reason}
      end
    else
      {:error, {:already_started, _pid}} -> {:error, :gateway_start_failed}
      {:error, {:shutdown, _reason}} -> {:error, :invalid_gateway_config}
      {:error, _reason} -> {:error, :invalid_gateway_config}
    end
  end

  defp start_bandit(pid, params, token) do
    with {:ok, admission} <- child_pid(pid, Admission),
         {:ok, bind} <- child_pid(pid, Bind),
         {:ok, secret} <- child_pid(pid, Secret),
         :ok <- Secret.install(secret, token),
         {:ok, bandit} <-
           Supervisor.start_child(pid, bandit_spec(params, admission, bind, secret)),
         {:ok, {_ip, port}} <- ThousandIsland.listener_info(bandit),
         :ok <- Bind.put(bind, {params.host, port}) do
      {:ok, bandit}
    else
      {:error, {:already_started, _pid}} -> {:error, :gateway_start_failed}
      {:error, {:shutdown, _reason}} -> {:error, :invalid_gateway_config}
      {:error, _reason} -> {:error, :invalid_gateway_config}
    end
  end

  defp bandit_spec(params, admission, bind, secret) do
    %{
      id: Bandit,
      start:
        {Bandit, :start_link,
         [
           [
             plug: {Router, router_config(params, admission, bind, secret)},
             scheme: :http,
             port: params.port,
             ip: params.ip,
             startup_log: false
           ]
         ]},
      restart: :temporary,
      significant: true,
      type: :supervisor
    }
  end

  defp router_config(params, admission, bind, secret) do
    [
      secret: secret,
      authority: bind,
      origin_allowlist: params.origin_allowlist,
      admission: admission,
      catalog: params.tools,
      tools: Catalog.index(params.tools)
    ]
  end

  defp params(opts) do
    tools = Keyword.get(opts, :tools, [])
    token = Keyword.get(opts, :token)
    ceiling = Keyword.get(opts, :max_in_flight, 8)
    ip = Keyword.get(opts, :ip, @loopback)
    port = Keyword.get(opts, :port, 4180)
    origin_allowlist = Keyword.get(opts, :origin_allowlist, [])

    with true <-
           Catalog.valid?(tools) and valid_token?(token) and is_integer(ceiling) and
             ceiling > 0 and ip in @addresses and is_integer(port) and port in 0..65_535 and
             valid_origins?(origin_allowlist),
         {:ok, host} <- canonical_host(ip, Keyword.get(opts, :host)) do
      {:ok,
       %{
         tools: tools,
         token: token,
         max_in_flight: ceiling,
         ip: ip,
         port: port,
         host: host,
         origin_allowlist: origin_allowlist
       }}
    else
      _reason -> {:error, :invalid_gateway_config}
    end
  end

  defp valid_token?(token) when is_binary(token) and token != "", do: true
  defp valid_token?(_token), do: false

  defp canonical_host(@wildcard, host), do: parse_host(host)

  defp canonical_host(_loopback, nil), do: {:ok, "127.0.0.1"}

  defp canonical_host(_loopback, host), do: parse_host(host)

  defp parse_host(host) when is_binary(host) and byte_size(host) in 1..253 do
    if host =~
         ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\z/ do
      {:ok, host}
    else
      :error
    end
  end

  defp parse_host(_host), do: :error

  defp valid_origins?(origins) when is_list(origins) do
    Enum.all?(origins, &(is_binary(&1) and &1 != ""))
  end

  defp valid_origins?(_origins), do: false

  defp child_pid(supervisor, id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value({:error, :invalid_gateway_config}, fn
      {^id, pid, _type, _modules} when is_pid(pid) -> {:ok, pid}
      _other -> nil
    end)
  end

  defp bandit_pid(supervisor), do: child_pid(supervisor, Bandit)
end
