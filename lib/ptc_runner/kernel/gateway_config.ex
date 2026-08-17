defmodule PtcRunner.Kernel.GatewayConfig do
  @moduledoc """
  Static gateway configuration document.

  A `tools` map names each served application, its source, approved
  description, and the expected `application_content_digest` /
  `effective_application_digest` pair plus per-occurrence provider snapshot
  digests. Boot and call-time revalidation compare those fields key by key.
  """

  @digest ~r/\A[0-9a-f]{64}\z/
  @effective ~r/\Asha256:[0-9a-f]{64}\z/
  @tool_name ~r/\A[^\s\x00-\x1f\x7f]{1,128}\z/u

  @type t :: %{
          path: binary(),
          max_in_flight: pos_integer(),
          host: binary() | nil,
          tools: [tool()]
        }

  @type tool :: %{
          name: binary(),
          description: binary(),
          source: {:directory, binary()},
          application_content_digest: binary(),
          effective_application_digest: binary(),
          providers: [map()]
        }

  @spec load(binary()) :: {:ok, t()} | {:error, :invalid_gateway_config}
  def load(path) when is_binary(path) and path != "" do
    with {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- Jason.decode(bytes),
         {:ok, config} <- parse(decoded, Path.dirname(Path.expand(path))) do
      {:ok, Map.put(config, :path, Path.expand(path))}
    else
      _reason -> {:error, :invalid_gateway_config}
    end
  end

  def load(_path), do: {:error, :invalid_gateway_config}

  defp parse(%{"version" => 1, "tools" => tools} = value, root) when is_map(tools) do
    admission = Map.get(value, "admission", %{})
    host = Map.get(value, "host")
    ceiling = Map.get(admission, "max_in_flight", 8)

    with true <- is_integer(ceiling) and ceiling > 0,
         true <- is_nil(host) or (is_binary(host) and host != ""),
         {:ok, parsed} <- parse_tools(tools, root) do
      {:ok,
       %{
         max_in_flight: ceiling,
         host: host && Path.expand(host, root),
         tools: parsed
       }}
    else
      _reason -> {:error, :invalid_gateway_config}
    end
  end

  defp parse(_value, _root), do: {:error, :invalid_gateway_config}

  defp parse_tools(tools, root) do
    tools
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {name, spec}, {:ok, acc} ->
      case parse_tool(name, spec, root) do
        {:ok, tool} -> {:cont, {:ok, acc ++ [tool]}}
        :error -> {:halt, {:error, :invalid_gateway_config}}
      end
    end)
  end

  defp parse_tool(name, spec, root) when is_binary(name) and is_map(spec) do
    with true <- name =~ @tool_name,
         description when is_binary(description) and description != "" <- spec["description"],
         %{"directory" => directory} <- spec["source"],
         true <- is_binary(directory) and directory != "",
         %{"application_content_digest" => content, "effective_application_digest" => effective} <-
           spec["digests"],
         true <- content =~ @digest,
         true <- effective =~ @effective,
         providers when is_list(providers) <- Map.get(spec["digests"], "providers", []) do
      {:ok,
       %{
         name: name,
         description: description,
         source: {:directory, Path.expand(directory, root)},
         application_content_digest: content,
         effective_application_digest: effective,
         providers: providers
       }}
    else
      _reason -> :error
    end
  end

  defp parse_tool(_name, _spec, _root), do: :error
end
