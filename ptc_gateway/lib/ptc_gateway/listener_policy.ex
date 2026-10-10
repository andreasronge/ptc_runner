defmodule PtcGateway.ListenerPolicy do
  @moduledoc false

  # One acceptor avoids rounding the per-acceptor connection limit. Eight
  # extra handlers allow a small keep-alive/health workload independent of
  # request admission; they are shared capacity, not reserved health slots.
  @headroom 8
  @base_reserve 128

  alias PtcRunner.Kernel.ServingTemplate

  def derive(config, host, tools) do
    admission = config["admission"]
    ceiling = admission["max_inflight_requests"] + @headroom

    # Pools can retain the active ceiling per installation. Acquisitions are
    # per declaration per tool, including repeated uses of one installation;
    # allow four descriptors each for stdio pipes/retained transport overhead.
    providers =
      map_size(host.install) * admission["max_active_provider_calls"] +
        4 * declaration_count(tools)

    artifacts = if config["artifacts"], do: 2 * admission["max_concurrent_runs"], else: 0
    reserve = @base_reserve + providers + artifacts

    with {:ok, limit} <- soft_descriptor_limit(),
         :ok <- validate(ceiling + 1 + reserve, limit) do
      {:ok,
       %{
         num_acceptors: 1,
         num_connections: ceiling,
         handler_ceiling: ceiling,
         idle_headroom: @headroom,
         descriptor_reserve: reserve,
         soft_descriptor_limit: limit
       }}
    end
  end

  defp declaration_count(tools) do
    Enum.reduce(tools, 0, fn {_, %{template: template}}, count ->
      case ServingTemplate.provider_plan(template) do
        {:ok, plan} -> count + length(plan.metadata.provider_declarations)
        {:error, :provider_runtime_required} -> count
      end
    end)
  end

  defp validate(_required, :unlimited), do: :ok
  defp validate(required, limit) when required <= limit, do: :ok
  defp validate(_, _), do: {:error, :listener_capacity_exceeded}

  # A child inherits this process's soft limit. Query the shell builtin rather
  # than a login shell, which could replace it from startup configuration.
  defp soft_descriptor_limit do
    case System.cmd("/bin/sh", ["-c", "ulimit -n"], stderr_to_stdout: true) do
      {output, 0} -> parse_limit(String.trim(output))
      _ -> {:error, :listener_capacity_unavailable}
    end
  rescue
    _ -> {:error, :listener_capacity_unavailable}
  end

  defp parse_limit("unlimited"), do: {:ok, :unlimited}

  defp parse_limit(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> {:ok, limit}
      _ -> {:error, :listener_capacity_unavailable}
    end
  end
end
