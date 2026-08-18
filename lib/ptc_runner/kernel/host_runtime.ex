defmodule PtcRunner.Kernel.HostRuntime do
  @moduledoc """
  Supervised per-VM singleton for hosted provider-backed serving.

  Owns provider-application lifecycle (`:req_llm` / `:llm_db` started once,
  dotenv disabled) and Finch pool geometry. Startup validates reversible
  configuration — pool geometry, the admission-ceiling invariant, and the
  credential resolver — before starting any VM-lifetime application. A
  refused startup therefore never leaves those applications running as a
  side effect of the failure.

  Applications this runtime starts are VM-lifetime: it never stops them,
  and it never stops applications it did not start. If `:req_llm` is
  already running, the runtime adopts it when dotenv is disabled and the
  admission ceiling fits the configured Finch capacity; conflicting
  configuration fails closed.

  Aggregate provider-task admission is a dedicated process supervised
  **above** this runtime's owner, with `restart: :temporary` and a
  `:persistent_term` claim taken at birth. Owner death poisons the VM
  until restart. Dispatch-level checkout is non-blocking: saturation and
  poison yield closed diagnostics rather than a queue.

  `call/3` supplies only the input value. Per-call provider acquisition
  still happens; pooled retention of provider services is out of scope.

  ## Options

  `start_link/1` accepts `:pool_count`, `:pool_size`, `:admission_ceiling`,
  `:credential_resolver`, and `:installed_limits`. Unknown and duplicate
  options fail before any application is started. `:admission_ceiling`
  must not exceed `pool_count * pool_size`. When `:req_llm` is not yet
  running, the default pool is one shard whose size is the installed
  `live_provider_tasks` ceiling.

  ## Errors

  Startup may return `:invalid_host_runtime_options`,
  `:admission_ceiling_exceeds_pool`, `:provider_application_conflict`,
  `:pool_geometry_unverified`, `:admission_owner_dead`, or the OTP
  `{:already_started, pid}` tuple.
  """

  use Supervisor

  alias PtcRunner.Kernel.HostRuntimeOwner
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderAdmission
  alias PtcRunner.Kernel.ProviderApplicationGate
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ServingTemplate

  @start_options [
    :pool_count,
    :pool_size,
    :admission_ceiling,
    :credential_resolver,
    :installed_limits
  ]

  @doc "Starts the per-VM host runtime supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start() | {:error, atom()}
  def start_link(opts \\ [])

  def start_link(opts) when is_list(opts) do
    with {:ok, config} <- build_config(opts),
         :ok <- ensure_provider_applications(config) do
      case start_supervisor(config) do
        {:ok, _pid} = started ->
          started

        {:error, {:already_started, pid}} ->
          {:error, {:already_started, pid}}

        {:error, {:shutdown, reason}} ->
          admission_start_error(reason)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def start_link(_opts), do: {:error, :invalid_host_runtime_options}

  @impl Supervisor
  def init(config) do
    children = [
      {ProviderAdmission, ceiling: config.admission_ceiling},
      {HostRuntimeOwner, config}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Executes one call against a compiled template under this runtime."
  @spec call(pid() | module(), ServingTemplate.t(), map(), keyword()) ::
          {:ok, PtcRunner.Kernel.CommandOutcome.t()}
          | {:error,
             PtcRunner.Kernel.CommandOutcome.t()
             | :invalid_host_runtime
             | :invalid_serving_template
             | :entropy_unavailable}
  def call(runtime, template, input, opts \\ [])

  def call(runtime, %ServingTemplate{} = template, input, opts)
      when (is_pid(runtime) or runtime == __MODULE__) and is_map(input) and not is_struct(input) and
             is_list(opts) do
    if runtime_alive?(runtime) and ServingTemplate.valid?(template) and opts == [] do
      dispatch(template, input)
    else
      {:error, :invalid_host_runtime}
    end
  end

  def call(_runtime, _template, _input, _opts), do: {:error, :invalid_host_runtime}

  @doc "Returns true when the runtime supervisor and admission owner are alive."
  @spec ready?(pid() | module()) :: boolean()
  def ready?(runtime) when is_pid(runtime) or runtime == __MODULE__ do
    runtime_alive?(runtime) and is_pid(Process.whereis(ProviderAdmission))
  end

  def ready?(_runtime), do: false

  @doc "Returns the frozen aggregate admission ceiling."
  @spec admission_ceiling(pid() | module()) :: pos_integer() | nil
  def admission_ceiling(runtime) when is_pid(runtime) or runtime == __MODULE__ do
    if runtime_alive?(runtime), do: ProviderAdmission.ceiling()
  end

  def admission_ceiling(_runtime), do: nil

  defp dispatch(template, input) do
    case HostRuntimeOwner.config() do
      {:ok, config} ->
        ServingTemplate.dispatch_hosted(template, input, config.services)

      {:error, _reason} = error ->
        error
    end
  end

  defp runtime_alive?(runtime) when runtime == __MODULE__,
    do: is_pid(Process.whereis(__MODULE__)) and match?({:ok, _config}, HostRuntimeOwner.config())

  defp runtime_alive?(pid) when is_pid(pid),
    do: Process.alive?(pid) and Process.whereis(__MODULE__) == pid

  defp build_config(opts) do
    with :ok <- validate_options(opts),
         {:ok, installed_limits} <- installed_limits(opts),
         {:ok, pool_count, pool_size} <- pool_geometry(opts, installed_limits),
         {:ok, ceiling} <- admission_ceiling_option(opts, pool_count, pool_size),
         {:ok, resolver} <- credential_resolver(opts),
         {:ok, services} <-
           ProviderRuntimeServices.new(
             provider_application_mode: :host_owned,
             credential_resolver: resolver
           ) do
      {:ok,
       %{
         installed_limits: installed_limits,
         pool_count: pool_count,
         pool_size: pool_size,
         admission_ceiling: ceiling,
         services: services
       }}
    end
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      if keys -- @start_options == [] and length(keys) == MapSet.size(MapSet.new(keys)) do
        :ok
      else
        {:error, :invalid_host_runtime_options}
      end
    else
      {:error, :invalid_host_runtime_options}
    end
  end

  defp installed_limits(opts) do
    case Keyword.get(opts, :installed_limits, Limits.installed_defaults()) do
      %Limits{} = limits ->
        if Limits.valid?(limits),
          do: {:ok, limits},
          else: {:error, :invalid_host_runtime_options}

      _other ->
        {:error, :invalid_host_runtime_options}
    end
  end

  defp pool_geometry(opts, installed_limits) do
    count = Keyword.get(opts, :pool_count, 1)
    size = Keyword.get(opts, :pool_size, installed_limits.live_provider_tasks)

    if is_integer(count) and count > 0 and is_integer(size) and size > 0 do
      {:ok, count, size}
    else
      {:error, :invalid_host_runtime_options}
    end
  end

  defp admission_ceiling_option(opts, pool_count, pool_size) do
    capacity = pool_count * pool_size
    ceiling = Keyword.get(opts, :admission_ceiling, capacity)

    cond do
      not is_integer(ceiling) or ceiling < 1 ->
        {:error, :invalid_host_runtime_options}

      ceiling > capacity ->
        {:error, :admission_ceiling_exceeds_pool}

      true ->
        {:ok, ceiling}
    end
  end

  defp credential_resolver(opts) do
    case Keyword.get(opts, :credential_resolver, &default_credential_resolver/1) do
      resolver when is_function(resolver, 1) -> {:ok, resolver}
      _other -> {:error, :invalid_host_runtime_options}
    end
  end

  defp default_credential_resolver(_names), do: {:error, :credential_unavailable}

  defp ensure_provider_applications(config) do
    running = running_applications()

    if MapSet.member?(running, :req_llm) do
      adopt_running_req_llm(config)
    else
      start_req_llm(config)
    end
  end

  defp adopt_running_req_llm(config) do
    if Application.get_env(:req_llm, :load_dotenv, true) == false and
         Application.get_env(:llm_db, :load_dotenv, true) == false and
         default_http1_pool?() and
         running_pool_capacity() >= config.admission_ceiling do
      :ok
    else
      {:error, :provider_application_conflict}
    end
  end

  defp start_req_llm(config) do
    if default_http1_pool?() do
      :ok = ProviderApplicationGate.configure_command_vm_req_llm(config.installed_limits)
      Application.put_env(:req_llm, :stream_pool_count, config.pool_count, persistent: true)
      Application.put_env(:req_llm, :stream_pool_size, config.pool_size, persistent: true)

      case Application.ensure_all_started(:req_llm) do
        {:ok, _started} -> :ok
        {:error, _reason} -> {:error, :provider_application_conflict}
      end
    else
      {:error, :pool_geometry_unverified}
    end
  end

  defp running_pool_capacity do
    count = Application.get_env(:req_llm, :stream_pool_count, 1)
    size = Application.get_env(:req_llm, :stream_pool_size, 1)

    if is_integer(count) and count > 0 and is_integer(size) and size > 0,
      do: count * size,
      else: 0
  end

  defp default_http1_pool? do
    protocols = Application.get_env(:req_llm, :stream_pool_protocols, [:http1])
    finch = Application.get_env(:req_llm, :finch, [])

    protocols == [:http1] and Keyword.keyword?(finch) and not Keyword.has_key?(finch, :pools)
  end

  defp start_supervisor(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  catch
    :exit, reason ->
      if claimed_exit?(reason),
        do: {:error, :admission_owner_dead},
        else: {:error, {:supervisor_exit, reason}}
  end

  defp claimed_exit?({:shutdown, reason}), do: admission_claimed_shutdown?(reason)
  defp claimed_exit?({{:shutdown, reason}, _stack}), do: admission_claimed_shutdown?(reason)
  defp claimed_exit?(_reason), do: false

  defp running_applications do
    Application.started_applications() |> MapSet.new(&elem(&1, 0))
  end

  defp admission_claimed_shutdown?({:failed_to_start_child, ProviderAdmission, reason}) do
    reason in [:admission_claimed, {:shutdown, :admission_claimed}]
  end

  defp admission_claimed_shutdown?(_reason), do: false

  defp admission_start_error(reason) do
    if admission_claimed_shutdown?(reason),
      do: {:error, :admission_owner_dead},
      else: {:error, {:shutdown, reason}}
  end
end
