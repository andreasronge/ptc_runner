defmodule PtcRunner.CapabilityRegistry.Persistence do
  @moduledoc """
  JSON serialization and persistence for the Capability Registry.

  Provides functions to save and load the registry to/from JSON files.
  Base tool functions are stored as references and resolved on load.

  ## Serialization Strategy

  - PTC-Lisp code is stored as text
  - Base tool functions are stored as `{:base_ref, id}`
  - DateTime fields are ISO8601 strings
  - History is bounded to prevent unbounded growth

  ## Usage

      # Save registry to file
      :ok = Persistence.persist_json(registry, "registry.json")

      # Load registry with base tool resolver
      {:ok, registry} = Persistence.load_json("registry.json", fn id ->
        Map.get(my_base_tools, id)
      end)

  """

  alias PtcRunner.CapabilityRegistry.{Capability, Registry, Skill, TestSuite, ToolEntry}

  @max_history_on_save 10_000

  @doc """
  Persists registry to a JSON file.

  ## Options

  - `:pretty` - Format JSON with indentation (default: true)

  """
  @spec persist_json(Registry.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def persist_json(registry, path, opts \\ []) do
    pretty = Keyword.get(opts, :pretty, true)

    data = to_json(registry)

    case Jason.encode(data, pretty: pretty) do
      {:ok, json} ->
        File.write(path, json)

      {:error, reason} ->
        {:error, {:encode_failed, reason}}
    end
  end

  @doc """
  Loads registry from a JSON file.

  Requires a function resolver for base tools since functions can't be
  serialized.

  ## Parameters

  - `path` - Path to JSON file
  - `function_resolver` - Function that takes a tool ID and returns
    the Elixir function, or nil if not found

  """
  @spec load_json(String.t(), (String.t() -> (map() -> term()) | nil)) ::
          {:ok, Registry.t()} | {:error, term()}
  def load_json(path, function_resolver \\ fn _ -> nil end) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      from_json(data, function_resolver)
    else
      {:error, %Jason.DecodeError{} = e} ->
        {:error, {:json_decode_failed, e}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Converts registry to a JSON-serializable map.
  """
  @spec to_json(Registry.t()) :: map()
  def to_json(registry) do
    %{
      version: "1.0",
      exported_at: DateTime.to_iso8601(DateTime.utc_now()),
      capabilities: capabilities_to_json(registry.capabilities),
      tools: tools_to_json(registry.tools),
      skills: skills_to_json(registry.skills),
      test_suites: test_suites_to_json(registry.test_suites),
      health: health_to_json(registry.health),
      history: Enum.take(registry.history, @max_history_on_save) |> history_to_json(),
      promotion_candidates: promotion_candidates_to_json(registry.promotion_candidates),
      archived: archived_to_json(registry.archived)
    }
  end

  @doc """
  Creates registry from a JSON map.
  """
  @spec from_json(map(), (String.t() -> (map() -> term()) | nil)) ::
          {:ok, Registry.t()} | {:error, term()}
  def from_json(data, function_resolver) do
    # Normalize keys to strings (handles both atom keys from to_json and string keys from JSON decode)
    data = stringify_keys(data)

    with {:ok, capabilities} <- capabilities_from_json(data["capabilities"] || %{}),
         {:ok, tools} <- tools_from_json(data["tools"] || %{}, function_resolver),
         {:ok, skills} <- skills_from_json(data["skills"] || %{}),
         {:ok, test_suites} <- test_suites_from_json(data["test_suites"] || %{}),
         {:ok, health} <- health_from_json(data["health"] || %{}),
         {:ok, history} <- history_from_json(data["history"] || []),
         {:ok, promotion_candidates} <-
           promotion_candidates_from_json(data["promotion_candidates"] || %{}),
         {:ok, archived} <- archived_from_json(data["archived"] || %{}, function_resolver) do
      {:ok,
       %Registry{
         capabilities: capabilities,
         tools: tools,
         skills: skills,
         test_suites: test_suites,
         health: health,
         history: history,
         promotion_candidates: promotion_candidates,
         archived: archived,
         embeddings: nil
       }}
    end
  end

  # ============================================================================
  # Capabilities
  # ============================================================================

  defp capabilities_to_json(capabilities) do
    Map.new(capabilities, fn {id, cap} ->
      {id, Capability.to_json(cap)}
    end)
  end

  defp capabilities_from_json(data) do
    result =
      Enum.reduce_while(data, {:ok, %{}}, fn {id, cap_data}, {:ok, acc} ->
        case Capability.from_json(cap_data) do
          {:ok, cap} -> {:cont, {:ok, Map.put(acc, id, cap)}}
          error -> {:halt, error}
        end
      end)

    result
  end

  # ============================================================================
  # Tools
  # ============================================================================

  defp tools_to_json(tools) do
    Map.new(tools, fn {id, tool} ->
      {id, ToolEntry.to_json(tool)}
    end)
  end

  defp tools_from_json(data, function_resolver) do
    result =
      Enum.reduce_while(data, {:ok, %{}}, fn {id, tool_data}, {:ok, acc} ->
        case ToolEntry.from_json(tool_data, function_resolver) do
          {:ok, tool} -> {:cont, {:ok, Map.put(acc, id, tool)}}
          error -> {:halt, error}
        end
      end)

    result
  end

  # ============================================================================
  # Skills
  # ============================================================================

  defp skills_to_json(skills) do
    Map.new(skills, fn {id, skill} ->
      {id, Skill.to_json(skill)}
    end)
  end

  defp skills_from_json(data) do
    result =
      Enum.reduce_while(data, {:ok, %{}}, fn {id, skill_data}, {:ok, acc} ->
        case Skill.from_json(skill_data) do
          {:ok, skill} -> {:cont, {:ok, Map.put(acc, id, skill)}}
          error -> {:halt, error}
        end
      end)

    result
  end

  # ============================================================================
  # Test Suites
  # ============================================================================

  defp test_suites_to_json(suites) do
    Map.new(suites, fn {id, suite} ->
      {id, TestSuite.to_json(suite)}
    end)
  end

  defp test_suites_from_json(data) do
    result =
      Enum.reduce_while(data, {:ok, %{}}, fn {id, suite_data}, {:ok, acc} ->
        case TestSuite.from_json(suite_data) do
          {:ok, suite} -> {:cont, {:ok, Map.put(acc, id, suite)}}
          error -> {:halt, error}
        end
      end)

    result
  end

  # ============================================================================
  # Health
  # ============================================================================

  defp health_to_json(health) do
    Map.new(health, fn {id, status} ->
      {id, Atom.to_string(status)}
    end)
  end

  defp health_from_json(data) do
    result =
      Map.new(data, fn {id, status} ->
        {id, String.to_existing_atom(status)}
      end)

    {:ok, result}
  rescue
    e -> {:error, {:health_parse_failed, e}}
  end

  # ============================================================================
  # History
  # ============================================================================

  defp history_to_json(history) do
    Enum.map(history, fn trial ->
      %{
        tool_id: trial.tool_id,
        context_tags: trial.context_tags,
        success: trial.success,
        timestamp: DateTime.to_iso8601(trial.timestamp)
      }
    end)
  end

  defp history_from_json(data) do
    result =
      Enum.map(data, fn trial ->
        {:ok, ts, _} = DateTime.from_iso8601(trial["timestamp"])

        %{
          tool_id: trial["tool_id"],
          context_tags: trial["context_tags"] || [],
          success: trial["success"],
          timestamp: ts
        }
      end)

    {:ok, result}
  rescue
    e -> {:error, {:history_parse_failed, e}}
  end

  # ============================================================================
  # Promotion Candidates
  # ============================================================================

  defp promotion_candidates_to_json(candidates) do
    Map.new(candidates, fn {hash, candidate} ->
      {hash,
       %{
         pattern_hash: candidate.pattern_hash,
         capability_signature: candidate.capability_signature,
         occurrences: Enum.map(candidate.occurrences, &occurrence_to_json/1),
         status: Atom.to_string(candidate.status),
         rejection_reason: candidate.rejection_reason,
         created_at: DateTime.to_iso8601(candidate.created_at)
       }}
    end)
  end

  defp occurrence_to_json(occ) do
    %{
      mission: occ.mission,
      result: if(occ.result == :success, do: "success", else: "failure"),
      timestamp: DateTime.to_iso8601(occ.timestamp)
    }
  end

  defp promotion_candidates_from_json(data) do
    result =
      Map.new(data, fn {hash, candidate} ->
        {:ok, created_at, _} = DateTime.from_iso8601(candidate["created_at"])

        occurrences =
          Enum.map(candidate["occurrences"] || [], fn occ ->
            {:ok, ts, _} = DateTime.from_iso8601(occ["timestamp"])

            %{
              mission: occ["mission"],
              result: if(occ["result"] == "success", do: :success, else: :failure),
              timestamp: ts
            }
          end)

        {hash,
         %{
           pattern_hash: candidate["pattern_hash"],
           capability_signature: candidate["capability_signature"],
           occurrences: occurrences,
           status: String.to_existing_atom(candidate["status"]),
           rejection_reason: candidate["rejection_reason"],
           created_at: created_at
         }}
      end)

    {:ok, result}
  rescue
    e -> {:error, {:promotion_candidates_parse_failed, e}}
  end

  # ============================================================================
  # Archived
  # ============================================================================

  defp archived_to_json(archived) do
    Map.new(archived, fn {id, entry} ->
      {id,
       %{
         type: Atom.to_string(entry.type),
         entry:
           case entry.type do
             :tool -> ToolEntry.to_json(entry.entry)
             :skill -> Skill.to_json(entry.entry)
           end,
         archived_at: DateTime.to_iso8601(entry.archived_at),
         reason: entry.reason
       }}
    end)
  end

  defp archived_from_json(data, function_resolver) do
    result =
      Enum.reduce_while(data, {:ok, %{}}, fn {id, entry_data}, {:ok, acc} ->
        {:ok, archived_at, _} = DateTime.from_iso8601(entry_data["archived_at"])
        type = String.to_existing_atom(entry_data["type"])

        entry_result =
          case type do
            :tool -> ToolEntry.from_json(entry_data["entry"], function_resolver)
            :skill -> Skill.from_json(entry_data["entry"])
          end

        case entry_result do
          {:ok, entry} ->
            {:cont,
             {:ok,
              Map.put(acc, id, %{
                type: type,
                entry: entry,
                archived_at: archived_at,
                reason: entry_data["reason"]
              })}}

          error ->
            {:halt, error}
        end
      end)

    result
  end

  # ============================================================================
  # Key Normalization
  # ============================================================================

  # Recursively converts atom keys to string keys for consistent access
  # Handles both atom keys from to_json and string keys from Jason.decode
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
