defmodule NamedMissionWriterServer do
  @moduledoc false

  def main([root]) do
    root = Path.expand(root)
    :ok = File.mkdir_p(root)
    loop(root)
  end

  defp loop(root) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      line when is_binary(line) ->
        line |> :json.decode() |> handle(root)
        loop(root)
    end
  end

  defp handle(%{"id" => id, "method" => "server/discover"}, _root) do
    reply(id, %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{}},
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{
          "name" => "named-mission-writer",
          "version" => "1.0"
        }
      },
      "ttlMs" => 0,
      "cacheScope" => "private"
    })
  end

  defp handle(%{"id" => id, "method" => "tools/list"}, _root) do
    reply(id, %{
      "resultType" => "complete",
      "tools" => [
        %{
          "name" => "write_text_file",
          "description" => "Replace one UTF-8 file in the writer mission's private root.",
          "inputSchema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["path", "content"],
            "properties" => %{
              "path" => %{"type" => "string", "pattern" => "^[a-z0-9][a-z0-9._-]*$"},
              "content" => %{"type" => "string", "maxLength" => 65_536}
            }
          },
          "outputSchema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["path", "bytes"],
            "properties" => %{
              "path" => %{"type" => "string"},
              "bytes" => %{"type" => "integer", "minimum" => 0}
            }
          }
        }
      ],
      "ttlMs" => 0,
      "cacheScope" => "private"
    })
  end

  defp handle(
         %{
           "id" => id,
           "method" => "tools/call",
           "params" => %{
             "name" => "write_text_file",
             "arguments" => %{"path" => path, "content" => content}
           }
         },
         root
       )
       when is_binary(path) and is_binary(content) do
    if path =~ ~r/\A[a-z0-9][a-z0-9._-]*\z/ and byte_size(content) <= 65_536 do
      destination = Path.join(root, path)

      case File.lstat(destination) do
        {:ok, %{type: type}} when type != :regular -> fail(id, "destination_not_regular")
        _missing_or_regular -> write(id, destination, path, content)
      end
    else
      fail(id, "invalid_arguments")
    end
  end

  defp handle(%{"id" => id}, _root), do: fail(id, "unsupported_request")
  defp handle(_notification, _root), do: :ok

  defp write(id, destination, path, content) do
    case File.write(destination, content, [:binary]) do
      :ok ->
        reply(id, %{
          "resultType" => "complete",
          "structuredContent" => %{"path" => path, "bytes" => byte_size(content)},
          "content" => []
        })

      {:error, _reason} ->
        fail(id, "write_failed")
    end
  end

  defp fail(id, reason) do
    reply(id, %{
      "resultType" => "complete",
      "isError" => true,
      "content" => [%{"type" => "text", "text" => reason}]
    })
  end

  defp reply(id, result) do
    IO.write(:stdio, [:json.encode(%{"jsonrpc" => "2.0", "id" => id, "result" => result}), "\n"])
  end
end

NamedMissionWriterServer.main(System.argv())
