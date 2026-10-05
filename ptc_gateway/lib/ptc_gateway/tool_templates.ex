defmodule PtcGateway.ToolTemplates do
  @moduledoc false
  alias PtcRunner.Kernel.{HostConfig, MCPProtocol, ServingTemplate}

  @doc false
  def load_host(path) do
    case HostConfig.load(path) do
      {:ok, host} -> {:ok, host}
      _ -> {:error, :host_invalid}
    end
  end

  def build(entries, host, catalog, artifacts) do
    Enum.reduce_while(entries, {:ok, %{}, []}, fn entry, {:ok, tools, metadata} ->
      case template(entry, host, catalog, artifacts) do
        {:ok, template} ->
          pins = %{
            installation_config_pins: entry["installation_config_pins"],
            provider_snapshot_pins: entry["provider_snapshot_pins"]
          }

          safe = %{
            "name" => entry["name"],
            "title" => entry["title"],
            "description" => entry["description"],
            "inputSchema" => ServingTemplate.input_schema(template),
            "outputSchema" => ServingTemplate.output_schema(template),
            "annotations" => %{"readOnlyHint" => ServingTemplate.effect(template) == :read}
          }

          {:cont,
           {:ok, Map.put(tools, entry["name"], %{template: template, pins: pins}),
            metadata ++ [safe]}}

        {:error, code} ->
          {:halt, {:error, code}}
      end
    end)
  end

  def validate_catalog(tools) do
    schemas = Enum.flat_map(tools, &[&1["inputSchema"], &1["outputSchema"]])

    listing = %{
      "jsonrpc" => "2.0",
      "id" => String.duplicate(<<0>>, 256),
      "result" => %{
        "resultType" => "complete",
        "tools" => tools,
        "ttlMs" => 0,
        "cacheScope" => "private"
      }
    }

    cond do
      not Enum.all?(tools, &valid_header_schema?/1) ->
        {:error, :template_invalid}

      Enum.all?(schemas, &(encoded_size(&1) <= 65_536)) and
        within_static_limit?(tools) and within_static_limit?(listing) ->
        :ok

      true ->
        {:error, :catalog_too_large}
    end
  end

  defp valid_header_schema?(tool),
    do: match?({:ok, _parameters}, MCPProtocol.header_parameters(tool["inputSchema"]))

  @doc false
  def within_static_limit?(value), do: encoded_size(value) <= 4_194_304

  defp encoded_size(value) do
    case PtcRunner.Kernel.DeterministicJSON.encode(value) do
      {:ok, bytes} -> byte_size(bytes)
      _ -> 4_194_305
    end
  end

  defp template(entry, host, catalog, artifacts) do
    opts = [
      providers: catalog,
      inspection_capture: artifacts != nil and artifacts["inspection"] == true
    ]

    opts =
      if Map.has_key?(entry, "expected_application_content_digest"),
        do:
          Keyword.put(
            opts,
            :expected_application_content_digest,
            entry["expected_application_content_digest"]
          ),
        else: opts

    case ServingTemplate.from_directory(entry["application"]["manifest"], host.limits, opts) do
      {:ok, template} ->
        if ServingTemplate.effect(template) == :write and not entry["allow_write"],
          do: {:error, :write_forbidden},
          else: {:ok, template}

      {:error, %{code: :application_content_digest_mismatch}} ->
        {:error, :application_content_digest_mismatch}

      {:error, :provider_runtime_unsupported} ->
        {:error, :provider_source_unsupported}

      {:error, :application_content_digest_mismatch} ->
        {:error, :application_content_digest_mismatch}

      _ ->
        {:error, :template_invalid}
    end
  end
end
