defmodule IncidentCompiler.EvidenceServer do
  @moduledoc """
  Read-only stdio MCP server over hand-authored incident evidence corpora.

  This is a fixture server for the incident-evidence compiler reference
  application, not a production integration. It holds every corpus in memory,
  answers only the three read-effect evidence tools plus a snapshot-identity
  tool, and has no write path of any kind.

  Every record's `content_digest` is derived here from the record's own fields
  rather than authored in the corpus file, so a citation digest cannot drift
  from the evidence it names.
  """

  @protocol "2026-07-28"
  @record_fields ~w(body evidence_id observed_at source title)
  @default_limit 20
  @max_limit 50

  def main(argv) do
    corpora = argv |> corpus_dir() |> load_corpora()
    loop(corpora)
  end

  defp corpus_dir(["--corpus-dir", dir | _rest]), do: dir

  defp corpus_dir(_argv) do
    IO.puts(:stderr, "usage: evidence_server.exs --corpus-dir DIR")
    System.halt(64)
  end

  ## Corpus loading

  # Only `incident.json` and `evidence/records.json` are ever opened. The
  # sibling `oracle/` directory holds the answer key for offline scoring and
  # must never become reachable through a tool, so this server has no code
  # path that reads it.
  defp load_corpora(dir) do
    dir
    |> Path.join("*/incident.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Map.new(fn path ->
      incident = path |> File.read!() |> decode!()

      records =
        path
        |> Path.dirname()
        |> Path.join("evidence/records.json")
        |> File.read!()
        |> decode!()

      {incident["incident_id"], Map.put(incident, "records", digest_records(records))}
    end)
  end

  defp digest_records(records) do
    records
    |> Enum.map(&Map.put(&1, "content_digest", record_digest(&1)))
    |> Enum.sort_by(&{&1["observed_at"], &1["evidence_id"]})
  end

  # Canonical over an explicit ordered field list: the digest must not depend
  # on map iteration order or on fields a later corpus revision might add.
  defp record_digest(record) do
    @record_fields
    |> Enum.map(&[&1, Map.fetch!(record, &1)])
    |> sha256()
  end

  defp snapshot_hash(corpora) do
    corpora
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {incident_id, corpus} ->
      [incident_id, Enum.map(corpus["records"], & &1["content_digest"])]
    end)
    |> sha256()
  end

  defp sha256(term) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, encode(term)), case: :lower)
  end

  ## Transport

  defp loop(corpora) do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        line |> String.trim() |> dispatch(corpora)
        loop(corpora)

      _eof ->
        :ok
    end
  end

  defp dispatch("", _corpora), do: :ok

  defp dispatch(line, corpora) do
    case decode(line) do
      {:ok, %{"id" => id, "method" => method} = request} when is_integer(id) ->
        respond(id, handle(method, request["params"] || %{}, corpora))

      _other ->
        :ok
    end
  end

  defp respond(id, {:error, code, message}) do
    write(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})
  end

  defp respond(id, {:ok, result}) do
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => Map.put(result, "resultType", "complete")
    })
  end

  defp write(message), do: IO.write(:stdio, [encode(message), "\n"])

  ## Methods

  defp handle("server/discover", _params, _corpora) do
    {:ok,
     %{
       "supportedVersions" => [@protocol],
       "capabilities" => %{"tools" => %{}},
       "ttlMs" => 0,
       "cacheScope" => "private",
       "_meta" => %{
         "io.modelcontextprotocol/serverInfo" => %{
           "name" => "incident-evidence-fixture",
           "version" => "0.1.0"
         }
       }
     }}
  end

  defp handle("tools/list", _params, _corpora),
    do: {:ok, %{"tools" => tools(), "ttlMs" => 0, "cacheScope" => "private"}}

  defp handle("tools/call", %{"name" => name, "arguments" => arguments}, corpora)
       when is_map(arguments) do
    call(name, arguments, corpora)
  end

  defp handle("tools/call", %{"name" => name}, corpora), do: call(name, %{}, corpora)

  defp handle(_method, _params, _corpora), do: {:error, -32_601, "method not found"}

  defp call("evidence_snapshot", _arguments, corpora),
    do: structured(%{"snapshot_hash" => snapshot_hash(corpora)})

  defp call("evidence_list_sources", %{"incident_id" => incident_id}, corpora) do
    with {:ok, corpus} <- fetch_corpus(corpora, incident_id) do
      by_source = Enum.group_by(corpus["records"], & &1["source"])

      sources =
        Enum.map(corpus["sources"], fn source ->
          records = Map.get(by_source, source["source"], [])

          %{
            "source" => source["source"],
            "description" => source["description"],
            "record_count" => length(records)
          }
          |> put_boundary("earliest", records, &List.first/1)
          |> put_boundary("latest", records, &List.last/1)
        end)

      structured(%{
        "incident_id" => incident_id,
        "title" => corpus["title"],
        "opened_at" => corpus["opened_at"],
        "sources" => sources
      })
    end
  end

  defp call("evidence_search", %{"incident_id" => incident_id} = arguments, corpora) do
    with {:ok, corpus} <- fetch_corpus(corpora, incident_id) do
      limit = limit(arguments["limit"])

      matched =
        corpus["records"]
        |> filter_source(arguments["source"])
        |> filter_query(arguments["query"])

      structured(%{
        "incident_id" => incident_id,
        "matched" => length(matched),
        "truncated" => length(matched) > limit,
        "records" => matched |> Enum.take(limit) |> Enum.map(&summary/1)
      })
    end
  end

  defp call(
         "evidence_get",
         %{"incident_id" => incident_id, "evidence_id" => evidence_id},
         corpora
       ) do
    with {:ok, corpus} <- fetch_corpus(corpora, incident_id) do
      case Enum.find(corpus["records"], &(&1["evidence_id"] == evidence_id)) do
        nil ->
          structured(%{"found" => false, "evidence_id" => evidence_id})

        record ->
          structured(%{"found" => true, "evidence_id" => evidence_id, "record" => record})
      end
    end
  end

  defp call(_name, _arguments, _corpora), do: tool_error("unknown tool or invalid arguments")

  ## Result helpers

  defp structured(value), do: {:ok, %{"structuredContent" => value, "content" => []}}

  defp tool_error(message) do
    {:ok, %{"isError" => true, "content" => [%{"type" => "text", "text" => message}]}}
  end

  defp fetch_corpus(corpora, incident_id) do
    case Map.fetch(corpora, incident_id) do
      {:ok, corpus} -> {:ok, corpus}
      :error -> tool_error("unknown incident_id")
    end
  end

  defp put_boundary(source, _key, [], _pick), do: source

  defp put_boundary(source, key, records, pick),
    do: Map.put(source, key, records |> pick.() |> Map.fetch!("observed_at"))

  defp limit(value) when is_integer(value) and value > 0, do: min(value, @max_limit)
  defp limit(_value), do: @default_limit

  defp filter_source(records, source) when is_binary(source),
    do: Enum.filter(records, &(&1["source"] == source))

  defp filter_source(records, _source), do: records

  defp filter_query(records, query) when is_binary(query) and query != "" do
    needle = String.downcase(query)

    Enum.filter(records, fn record ->
      String.contains?(String.downcase(record["title"] <> " " <> record["body"]), needle)
    end)
  end

  defp filter_query(records, _query), do: records

  defp summary(record),
    do: Map.take(record, ~w(evidence_id observed_at source title content_digest))

  ## Tool catalog

  defp tools do
    [
      %{
        "name" => "evidence_list_sources",
        "description" => "List the evidence sources available for one incident.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["incident_id"],
          "properties" => %{"incident_id" => %{"type" => "string", "maxLength" => 128}}
        },
        "outputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["incident_id", "title", "opened_at", "sources"],
          "properties" => %{
            "incident_id" => %{"type" => "string"},
            "title" => %{"type" => "string"},
            "opened_at" => %{"type" => "string"},
            "sources" => %{
              "type" => "array",
              "maxItems" => 32,
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["source", "description", "record_count"],
                "properties" => %{
                  "source" => %{"type" => "string"},
                  "description" => %{"type" => "string"},
                  "record_count" => %{"type" => "integer"},
                  "earliest" => %{"type" => "string"},
                  "latest" => %{"type" => "string"}
                }
              }
            }
          }
        }
      },
      %{
        "name" => "evidence_search",
        "description" =>
          "Search one incident's evidence records by free text and source. Returns record summaries with content digests; call evidence_get for the body.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["incident_id"],
          "properties" => %{
            "incident_id" => %{"type" => "string", "maxLength" => 128},
            "query" => %{"type" => "string", "maxLength" => 512},
            "source" => %{"type" => "string", "maxLength" => 64},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_limit}
          }
        },
        "outputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["incident_id", "matched", "truncated", "records"],
          "properties" => %{
            "incident_id" => %{"type" => "string"},
            "matched" => %{"type" => "integer"},
            "truncated" => %{"type" => "boolean"},
            "records" => %{
              "type" => "array",
              "maxItems" => @max_limit,
              "items" => summary_schema()
            }
          }
        }
      },
      %{
        "name" => "evidence_get",
        "description" =>
          "Fetch one evidence record by its identifier, including its body and content digest.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["incident_id", "evidence_id"],
          "properties" => %{
            "incident_id" => %{"type" => "string", "maxLength" => 128},
            "evidence_id" => %{"type" => "string", "maxLength" => 128}
          }
        },
        "outputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["found", "evidence_id"],
          "properties" => %{
            "found" => %{"type" => "boolean"},
            "evidence_id" => %{"type" => "string"},
            "record" => record_schema()
          }
        }
      },
      %{
        "name" => "evidence_snapshot",
        "description" => "Return the content identity of the installed evidence corpora.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{}
        },
        "outputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["snapshot_hash"],
          "properties" => %{"snapshot_hash" => %{"type" => "string", "format" => "sha256"}}
        }
      }
    ]
  end

  defp summary_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["evidence_id", "observed_at", "source", "title", "content_digest"],
      "properties" => %{
        "evidence_id" => %{"type" => "string"},
        "observed_at" => %{"type" => "string"},
        "source" => %{"type" => "string"},
        "title" => %{"type" => "string"},
        "content_digest" => %{"type" => "string", "format" => "sha256"}
      }
    }
  end

  defp record_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["evidence_id", "observed_at", "source", "title", "body", "content_digest"],
      "properties" => %{
        "evidence_id" => %{"type" => "string"},
        "observed_at" => %{"type" => "string"},
        "source" => %{"type" => "string"},
        "title" => %{"type" => "string"},
        "body" => %{"type" => "string"},
        "content_digest" => %{"type" => "string", "format" => "sha256"}
      }
    }
  end

  ## JSON

  defp encode(term), do: :json.encode(term)

  defp decode!(binary), do: :json.decode(binary)

  defp decode(binary) do
    {:ok, :json.decode(binary)}
  rescue
    _exception -> :error
  end
end

IncidentCompiler.EvidenceServer.main(System.argv())
