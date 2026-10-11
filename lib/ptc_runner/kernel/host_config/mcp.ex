defmodule PtcRunner.Kernel.HostConfig.MCP do
  @moduledoc false

  @max_tools 128
  @max_result_bytes 1_048_576
  @max_timeout_ms 300_000

  alias PtcRunner.Kernel.HostConfig.Transport

  import PtcRunner.Kernel.HostConfig.Common

  def mcp_installation(value, credentials) do
    allowed =
      ~w(source transport tools snapshot_identity installation_revision ceilings data_class accepts_data)

    with :ok <-
           exact_keys(
             value,
             allowed,
             ~w(source transport tools installation_revision)
           ),
         {:ok, transport} <-
           Transport.transport(value["transport"], credentials),
         {:ok, tools} <- tools(value["tools"]),
         {:ok, snapshot_identity} <-
           snapshot_identity(Map.get(value, "snapshot_identity"), tools),
         {:ok, installation_revision} <-
           revision(value["installation_revision"]),
         {:ok, ceilings} <- ceilings(Map.get(value, "ceilings", %{})),
         {:ok, data_class} <- data_class(Map.get(value, "data_class", "normal")),
         {:ok, accepts_data} <-
           accepts_data(Map.get(value, "accepts_data", ["normal"])) do
      {:ok,
       %{
         source: :mcp,
         transport: transport,
         tools: tools,
         snapshot_identity: snapshot_identity,
         installation_revision: installation_revision,
         ceilings: ceilings,
         data_class: data_class,
         accepts_data: accepts_data
       }}
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp tools(value) when is_map(value) and map_size(value) in 1..@max_tools do
    with {:ok, tools} <- reduce_named_map(value, &tool/2),
         public_names = Enum.map(tools, fn {_upstream, tool} -> tool.as end),
         true <- public_names == Enum.uniq(public_names) do
      {:ok, tools}
    else
      _reason -> {:error, :invalid_tools}
    end
  end

  defp tools(_value), do: {:error, :invalid_tools}

  defp snapshot_identity(nil, _tools), do: {:ok, nil}

  defp snapshot_identity(value, tools) when is_map(value) do
    with :ok <- exact_keys(value, ~w(tool field), ~w(tool field)),
         tool when is_binary(tool) <- value["tool"],
         %{effect: :read} <- Map.get(tools, tool),
         field when is_binary(field) <- value["field"],
         true <- valid_name?(field) do
      {:ok, %{tool: tool, field: field}}
    else
      _reason -> {:error, :invalid_snapshot_identity}
    end
  end

  defp snapshot_identity(_value, _tools), do: {:error, :invalid_snapshot_identity}

  defp ceilings(value) when is_map(value) do
    with :ok <-
           exact_keys(value, ~w(timeout_ms max_catalog_tools max_result_bytes), []),
         timeout_ms when is_integer(timeout_ms) and timeout_ms in 1..@max_timeout_ms <-
           Map.get(value, "timeout_ms", 5_000),
         max_catalog_tools when is_integer(max_catalog_tools) and max_catalog_tools in 1..128 <-
           Map.get(value, "max_catalog_tools", 128),
         max_result_bytes
         when is_integer(max_result_bytes) and max_result_bytes in 1..@max_result_bytes <-
           Map.get(value, "max_result_bytes", 1_000_000) do
      {:ok,
       %{
         timeout_ms: timeout_ms,
         max_catalog_tools: max_catalog_tools,
         max_result_bytes: max_result_bytes
       }}
    else
      _reason -> {:error, :invalid_ceilings}
    end
  end

  defp ceilings(_value), do: {:error, :invalid_ceilings}
end
