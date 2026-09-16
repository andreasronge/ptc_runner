defmodule PtcRunner.Kernel.GatewayConfig do
  @moduledoc """
  Version-1 gateway configuration contract and bounded strict decoder.

  `schema/0` owns the generated gateway schema. `load/1` rejects duplicate and
  unknown keys, validates structural bounds, then semantic origin, name and
  audit rules. Paths are anchored to the gateway document directory; nested
  host paths remain owned by the host loader. No credentials are read here.
  """
  alias PtcRunner.Kernel.{ConfinedFile, SchemaViolation, StrictJSON}

  @max_bytes 1_000_000
  @name "^[a-zA-Z0-9_.-]{1,128}$"
  @binding "^[a-z][a-z0-9._-]{0,127}$"
  @digest "^sha256:[0-9a-f]{64}$"

  @spec load(binary()) :: {:ok, map()} | {:error, atom()}
  def load(path) when is_binary(path) do
    path = Path.expand(path)

    with {:ok, bytes} <- ConfinedFile.read(Path.dirname(path), Path.basename(path), @max_bytes),
         {:ok, value} <- StrictJSON.decode(bytes),
         :ok <- structural(value),
         :ok <- semantics(value) do
      {:ok, anchor(value, Path.dirname(path))}
    else
      {:error, :duplicate_json_key} ->
        {:error, :duplicate_json_key}

      {:error, code}
      when code in [:config_invalid, :origin_invalid, :tool_name_duplicate, :audit_invalid] ->
        {:error, code}

      _ ->
        {:error, :config_unavailable}
    end
  end

  def load(_), do: {:error, :config_unavailable}

  defp structural(value) do
    case SchemaViolation.validate(value, schema()) do
      :ok -> if byte_bounds?(value, schema()), do: :ok, else: {:error, :config_invalid}
      _ -> {:error, :config_invalid}
    end
  end

  defp byte_bounds?(value, schema) when is_binary(value),
    do:
      byte_size(value) <= Map.get(schema, "maxLength", 4096) and
        not String.contains?(value, ["\u0000", "\r", "\n"])

  defp byte_bounds?(value, schema) when is_list(value),
    do: Enum.all?(value, &byte_bounds?(&1, schema["items"] || %{}))

  defp byte_bounds?(value, schema) when is_map(value) do
    Enum.all?(value, fn {key, item} ->
      byte_size(key) <= 256 and not String.contains?(key, ["\r", "\n"]) and
        byte_bounds?(
          item,
          get_in(schema, ["properties", key]) || schema["additionalProperties"] || %{}
        )
    end)
  end

  defp byte_bounds?(_, _), do: true

  defp semantics(value) do
    tools = value["tools"]
    origins = get_in(value, ["listen", "allowed_origins"]) || []

    cond do
      Enum.any?(origins, &(not origin?(&1))) ->
        {:error, :origin_invalid}

      length(Enum.uniq_by(tools, & &1["name"])) != length(tools) ->
        {:error, :tool_name_duplicate}

      Enum.any?(tools, &(&1["allow_write"] == true)) != Map.has_key?(value, "private_audit") ->
        {:error, :audit_invalid}

      true ->
        :ok
    end
  end

  @doc "Accepts only exact serialized HTTP(S) origins with canonical host and port."
  @spec origin?(binary()) :: boolean()
  def origin?(origin) do
    uri = URI.parse(origin)

    ascii?(origin) and origin_shape?(uri) and origin_port?(uri.port) and
      URI.to_string(uri) == origin and
      not String.contains?(origin, [" ", "\t", "\n", "\r", "\\", "%"])
  rescue
    _ -> false
  end

  defp origin_shape?(uri) do
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      uri.host == String.downcase(uri.host) and
      Enum.all?([uri.userinfo, uri.path, uri.query, uri.fragment], &is_nil/1)
  end

  defp origin_port?(port), do: is_integer(port) and port in 1..65_535

  defp ascii?(value), do: Enum.all?(:binary.bin_to_list(value), &(&1 in 33..126))

  defp anchor(value, directory) do
    value
    |> put_in(["host", "path"], Path.expand(value["host"]["path"], directory))
    |> update_in(["listen"], &Map.put_new(&1, "allowed_origins", []))
    |> update_in(["tools"], fn tools ->
      tools
      |> Enum.sort_by(& &1["name"])
      |> Enum.map(fn tool ->
        tool
        |> Map.put_new("allow_write", false)
        |> put_in(
          ["application", "manifest"],
          Path.expand(tool["application"]["manifest"], directory)
        )
      end)
    end)
    |> anchor_audit(directory)
  end

  defp anchor_audit(%{"private_audit" => audit} = value, directory),
    do: put_in(value, ["private_audit", "directory"], Path.expand(audit["directory"], directory))

  defp anchor_audit(value, _), do: value

  @doc "Canonical version-1 structural contract, including fixed resource bounds."
  @spec schema() :: map()
  def schema do
    object(
      %{
        "$schema" => %{"const" => "https://ptc-runner.dev/schemas/ptc-gateway-config.schema.json"},
        "version" => %{"const" => 1},
        "listen" =>
          object(
            %{
              "address" => %{"enum" => ["127.0.0.1", "::1"]},
              "port" => count(1, 65_535),
              "path" => %{"const" => "/mcp"},
              "allowed_origins" => %{
                "type" => "array",
                "maxItems" => 128,
                "uniqueItems" => true,
                "default" => [],
                "items" => string(1, 2048)
              }
            },
            ~w(address port path)
          ),
        "authentication" =>
          object(%{"bearer" => object(%{"binding" => pattern(@binding, 128)}, ["binding"])}, [
            "bearer"
          ]),
        "host" => object(%{"path" => path()}, ["path"]),
        "admission" =>
          object(
            %{
              "max_inflight_requests" => count(1, 65_535),
              "max_concurrent_runs" => count(1, 65_535),
              "max_active_provider_calls" => count(1, 65_535),
              "max_waiting_provider_calls" => count(0, 65_535)
            },
            ~w(max_inflight_requests max_concurrent_runs max_active_provider_calls max_waiting_provider_calls)
          ),
        "tools" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 128,
          "items" => tool_schema()
        },
        "private_audit" =>
          object(
            %{
              "directory" => path(),
              "max_file_bytes" => count(1024, 67_108_864),
              "max_retained_files" => count(2, 128)
            },
            ~w(directory max_file_bytes max_retained_files)
          )
      },
      ~w(version listen authentication host admission tools)
    )
    |> Map.merge(%{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://ptc-runner.dev/schemas/ptc-gateway-config.schema.json",
      "title" => "PtcRunner gateway configuration",
      "description" =>
        "Strict UTF-8 JSON, at most 1000000 bytes; duplicate object keys forbidden. String maxima are also byte maxima. Semantic rules are in the gateway reference."
    })
  end

  defp tool_schema do
    object(
      %{
        "name" => pattern(@name, 128),
        "title" => string(1, 256),
        "description" => string(1, 4096),
        "application" => object(%{"manifest" => path()}, ["manifest"]),
        "allow_write" => %{"type" => "boolean", "default" => false},
        "expected_application_content_digest" => pattern(@digest, 71),
        "installation_config_pins" => pins(@binding),
        "provider_snapshot_pins" => pins("^(workflow|mission)/[a-z][a-z0-9._-]{0,127}$")
      },
      ~w(name title description application expected_application_content_digest installation_config_pins provider_snapshot_pins)
    )
  end

  defp pins(key),
    do: %{
      "type" => "object",
      "maxProperties" => 128,
      "propertyNames" => %{"pattern" => key},
      "additionalProperties" => pattern(@digest, 71)
    }

  defp object(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  defp count(min, max), do: %{"type" => "integer", "minimum" => min, "maximum" => max}
  defp string(min, max), do: %{"type" => "string", "minLength" => min, "maxLength" => max}
  defp pattern(regex, max), do: Map.put(string(1, max), "pattern", regex)
  defp path, do: pattern("^[^\\x00]+$", 1024)
end
