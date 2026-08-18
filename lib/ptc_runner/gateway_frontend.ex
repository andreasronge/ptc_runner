defmodule PtcRunner.GatewayFrontend do
  @moduledoc """
  Serves compiled applications as MCP tools over stdio or streamable HTTP.

      ptc serve gateway.json

  Boot loads the static gateway document, compiles each tool into a
  `PtcRunner.Kernel.ServingTemplate`, and refuses startup on digest mismatch,
  missing contracts, or an effect that is not provably `:read`. When the
  document names `http`, the host loads the bearer token from a private file
  and binds loopback unless `listen` is `0.0.0.0`. Otherwise it serves stdio.
  The companion is optional: it ships in the assembled release and is absent
  from the Hex package, where this command reports `gateway_unavailable`.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.GatewayConfig
  alias PtcRunner.Kernel.GatewayToken
  alias PtcRunner.Kernel.HostRuntime
  alias PtcRunner.Kernel.ServingTemplate

  # See `PtcRunner.ViewerFrontend` for why every companion call goes through
  # `apply/3`.
  @gateway PtcGateway

  @spec run(CommandArguments.t(), CommandRuntime.t()) :: :ok | {:error, atom(), binary()}
  def run(arguments, runtime), do: run(arguments, runtime, [])

  @doc false
  @spec run(CommandArguments.t(), CommandRuntime.t(), keyword()) ::
          :ok | {:error, atom(), binary()}
  def run(
        %CommandArguments{command: :serve, application: path, options: options},
        %CommandRuntime{},
        opts
      )
      when is_binary(path) do
    if companion_installed?() do
      if options == %{} do
        serve(path, opts)
      else
        {:error, :invalid_arguments, "invalid serve command"}
      end
    else
      {:error, :gateway_unavailable, "the PTC Gateway companion is not installed in this build"}
    end
  rescue
    _exception -> {:error, :internal_error, "serve command failed"}
  catch
    _kind, _reason -> {:error, :internal_error, "serve command failed"}
  end

  def run(_arguments, _runtime, _opts),
    do: {:error, :invalid_arguments, "invalid serve command"}

  @doc false
  @spec compile(binary()) :: {:ok, map()} | {:error, atom()}
  def compile(path) when is_binary(path) do
    with {:ok, config} <- GatewayConfig.load(path),
         {:ok, tools} <- compile_tools(config.tools, []),
         {:ok, http} <- load_http(config.http) do
      {:ok, %{tools: tools, max_in_flight: config.max_in_flight, http: http}}
    end
  end

  def compile(_path), do: {:error, :invalid_gateway_config}

  defp serve(path, opts) do
    with {:ok, compiled} <- compile(path),
         {:ok, pid} <- start_gateway(compiled, opts) do
      await(pid)
    else
      {:error, :gateway_unavailable} ->
        {:error, :gateway_unavailable, "the PTC Gateway companion is not installed in this build"}

      {:error, :effect_not_read} ->
        {:error, :effect_not_read, "a served application is not provably read-only"}

      {:error, :digest_mismatch} ->
        {:error, :digest_mismatch,
         "a served application digest does not match the gateway document"}

      {:error, :invalid_gateway_token} ->
        {:error, :invalid_gateway_token,
         "gateway token file is missing, empty, or not a private regular file"}

      {:error, reason} ->
        {:error, reason, "could not start PTC Gateway"}
    end
  end

  defp compile_tools([], acc), do: {:ok, Enum.reverse(acc)}

  defp compile_tools([tool | rest], acc) do
    case compile_tool(tool) do
      {:ok, compiled} -> compile_tools(rest, [compiled | acc])
      {:error, _reason} = error -> error
    end
  end

  defp compile_tool(tool) do
    {:directory, directory} = tool.source
    manifest = Path.join(directory, "ptc.json")

    with {:ok, package} <- ApplicationPackage.package_directory(manifest),
         {:ok, template} <- ServingTemplate.compile(package),
         :ok <- verify_digests(tool, template),
         :ok <- verify_providers(tool, template) do
      {:ok, gateway_tool(tool, template)}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _reason -> {:error, :invalid_gateway_config}
    end
  end

  defp verify_digests(tool, template) do
    if template.package.application_content_digest == tool.application_content_digest and
         template.effective_application_digest == tool.effective_application_digest do
      :ok
    else
      {:error, :digest_mismatch}
    end
  end

  defp verify_providers(tool, template) do
    if tool.providers == [] and template.provider_declarations == [] do
      :ok
    else
      {:error, :digest_mismatch}
    end
  end

  defp gateway_tool(tool, template) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: template.package.contracts.input.schema,
      output_schema: template.package.contracts.result.schema,
      meta: %{
        "ptc/application_content_digest" => tool.application_content_digest,
        "ptc/effective_application_digest" => tool.effective_application_digest
      },
      call: fn input -> invoke(template, input) end
    }
  end

  defp invoke(template, input) do
    if template.provider_declarations == [] do
      project(ServingTemplate.call(template, input))
    else
      project(HostRuntime.call(HostRuntime, template, input))
    end
  end

  defp project({:ok, outcome}), do: success_value(outcome)
  defp project({:error, %CommandOutcome{} = outcome}), do: {:error, classify(outcome)}
  defp project({:error, :host_runtime_required}), do: {:error, :execution}
  defp project({:error, _reason}), do: {:error, :execution}

  defp success_value(outcome) do
    envelope = CommandOutcome.to_map(outcome)

    case envelope do
      %{"status" => "ok", "result" => %{"result_class" => "private"}} ->
        {:error, :private}

      %{"status" => "ok", "result" => %{"value" => value}} when is_map(value) ->
        {:ok, value}

      _other ->
        {:error, :execution}
    end
  end

  defp classify(outcome) do
    envelope = CommandOutcome.to_map(outcome)
    code = envelope["error"]["code"]

    cond do
      envelope["result"]["result_class"] == "private" -> :private
      code == "input_contract_failed" -> :input_contract
      code in ["result_invalid", "result_contract_failed"] -> :result_contract
      code == "provider_admission_saturated" -> :admission
      true -> :execution
    end
  end

  defp load_http(nil), do: {:ok, nil}

  defp load_http(http) when is_map(http) do
    case GatewayToken.load(http.token_file) do
      {:ok, token} -> {:ok, Map.put(http, :token, token)}
      {:error, :invalid_gateway_token} -> {:error, :invalid_gateway_token}
    end
  end

  @doc false
  @spec start(map(), keyword()) :: {:ok, pid()} | {:error, atom()}
  def start(compiled, opts \\ []) when is_map(compiled) and is_list(opts) do
    start_gateway(compiled, opts)
  end

  @doc false
  @spec stop(pid()) :: :ok
  def stop(pid), do: apply_stop(pid)

  defp start_gateway(compiled, opts) do
    if companion_installed?() do
      start_transport(compiled, opts)
    else
      {:error, :gateway_unavailable}
    end
  end

  defp start_transport(%{http: http} = compiled, _opts) when is_map(http) do
    apply_start_http(
      tools: compiled.tools,
      max_in_flight: compiled.max_in_flight,
      token: http.token,
      ip: http.listen,
      port: http.port,
      host: http.host,
      origin_allowlist: http.origin_allowlist
    )
  end

  defp start_transport(compiled, opts) do
    start_opts =
      [
        tools: compiled.tools,
        max_in_flight: compiled.max_in_flight
      ]
      |> maybe_put(:read, Keyword.get(opts, :read))
      |> maybe_put(:write, Keyword.get(opts, :write))

    apply_start(start_opts)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp apply_start(opts), do: apply(@gateway, :start, [opts])

  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp apply_start_http(opts), do: apply(@gateway, :start_http, [opts])

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp await(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      :stop ->
        Process.demonitor(ref, [:flush])
        apply_stop(pid)
        :ok

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        {:error, :gateway_stopped, "PTC Gateway stopped"}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp apply_stop(pid), do: apply(@gateway, :stop, [pid])

  defp companion_installed?, do: Code.ensure_loaded?(@gateway)
end
