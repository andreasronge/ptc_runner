defmodule PtcRunner.Lisp.Prompts do
  @moduledoc """
  Prompt loader for PTC-Lisp language references.

  Loads prompt snippets from `priv/prompts/` directory at compile time and
  provides compositions for common use cases.

  ## Available Prompts

  | Key | Description |
  |-----|-------------|
  | `:single_shot` | Base language reference (no memory docs) |
  | `:multi_turn` | Base + memory addon for conversational use |

  ## Raw Snippets

  | Key | File | Description |
  |-----|------|-------------|
  | `:base` | `lisp-base.md` | Core language reference |
  | `:addon_memory` | `lisp-addon-memory.md` | Memory persistence docs |

  ## Version Metadata

  Prompt files can include optional metadata headers:

      <!-- version: 2 -->
      <!-- date: 2025-01-15 -->
      <!-- changes: Removed threading examples -->

  Access metadata via `version/1` and `metadata/1`.

  ## Usage

      # For single-turn queries
      PtcRunner.Lisp.Prompts.get(:single_shot)

      # For multi-turn conversations
      PtcRunner.Lisp.Prompts.get(:multi_turn)

      # Raw snippets for custom compositions
      PtcRunner.Lisp.Prompts.get(:base) <> my_custom_addon

      # Use in SubAgent
      SubAgent.new(
        prompt: "...",
        system_prompt: %{language_spec: PtcRunner.Lisp.Prompts.get(:single_shot)}
      )
  """

  @prompts_dir Path.join(__DIR__, "../../../priv/prompts")
  @archive_dir Path.join(@prompts_dir, "archive")

  # Find all lisp-*.md files in main and archive directories
  @prompt_files (fn ->
                   @prompts_dir
                   |> Path.join("lisp-*.md")
                   |> Path.wildcard()
                 end).()

  @archive_files (fn ->
                    @archive_dir
                    |> Path.join("lisp-*.md")
                    |> Path.wildcard()
                  end).()

  for file <- @prompt_files ++ @archive_files do
    @external_resource file
  end

  # Parse metadata from file header (before PTC_PROMPT_START marker)
  @parse_metadata fn header ->
    ~r/<!--\s*(\w+):\s*(.+?)\s*-->/
    |> Regex.scan(header)
    |> Enum.reduce(%{}, fn [_full, k, v], acc ->
      parsed_key = String.to_atom(k)

      parsed_value =
        case parsed_key do
          :version ->
            case Integer.parse(String.trim(v)) do
              {int, _} -> int
              :error -> nil
            end

          _ ->
            String.trim(v)
        end

      Map.put(acc, parsed_key, parsed_value)
    end)
  end

  # Helper function to load a prompt file (content + metadata extraction)
  @load_prompt_file fn path, archived ->
    filename = Path.basename(path, ".md")

    key =
      filename
      |> String.replace_prefix("lisp-", "")
      |> String.replace("-", "_")
      |> String.to_atom()

    file_content = File.read!(path)

    {header, content} =
      case String.split(file_content, "<!-- PTC_PROMPT_START -->") do
        [before, after_start] ->
          trimmed_content =
            case String.split(after_start, "<!-- PTC_PROMPT_END -->") do
              [prompt_text, _after_end] -> String.trim(prompt_text)
              _ -> String.trim(after_start)
            end

          {before, trimmed_content}

        _ ->
          {file_content, String.trim(file_content)}
      end

    metadata = @parse_metadata.(header)

    {key, %{content: content, metadata: metadata, archived: archived}}
  end

  # Load all prompts at compile time (current prompts)
  @current_prompts (fn ->
                      @prompt_files
                      |> Enum.map(&@load_prompt_file.(&1, false))
                      |> Map.new()
                    end).()

  # Load archived prompts
  @archived_prompts (fn ->
                       @archive_files
                       |> Enum.map(&@load_prompt_file.(&1, true))
                       |> Map.new()
                     end).()

  # Combined prompts (current + archived)
  @prompts Map.merge(@current_prompts, @archived_prompts)

  # Compositions: predefined combinations of snippets
  @compositions %{
    single_shot: [:base],
    multi_turn: [:base, :addon_memory]
  }

  @doc """
  Get a prompt by key.

  Supports both raw snippets (`:base`, `:addon_memory`) and compositions
  (`:single_shot`, `:multi_turn`).

  ## Parameters

  - `key` - Atom identifying the prompt

  ## Returns

  The prompt content as a string, or nil if not found.

  ## Examples

      iex> prompt = PtcRunner.Lisp.Prompts.get(:single_shot)
      iex> is_binary(prompt)
      true

      iex> prompt = PtcRunner.Lisp.Prompts.get(:multi_turn)
      iex> String.contains?(prompt, "State Persistence")
      true

  """
  @spec get(atom()) :: String.t() | nil
  def get(key) when is_atom(key) do
    case Map.get(@compositions, key) do
      nil ->
        # Direct file lookup
        case Map.get(@prompts, key) do
          %{content: content} -> content
          nil -> nil
        end

      parts ->
        # Compose from parts
        parts
        |> Enum.map(&get_snippet/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")
    end
  end

  defp get_snippet(key) do
    case Map.get(@prompts, key) do
      %{content: content} -> content
      nil -> nil
    end
  end

  @doc """
  Get a prompt by key, raising if not found.

  ## Examples

      iex> prompt = PtcRunner.Lisp.Prompts.get!(:single_shot)
      iex> is_binary(prompt)
      true

  """
  @spec get!(atom()) :: String.t()
  def get!(key) when is_atom(key) do
    case get(key) do
      nil -> raise ArgumentError, "Unknown prompt: #{inspect(key)}. Available: #{inspect(list())}"
      content -> content
    end
  end

  @doc """
  Get the version number for a prompt.

  Returns the version from the prompt's metadata, or 1 if not specified.
  For compositions, returns the version of the first component.

  ## Examples

      iex> PtcRunner.Lisp.Prompts.version(:base)
      3

  """
  @spec version(atom()) :: pos_integer()
  def version(key) when is_atom(key) do
    # For compositions, use the first component's version
    actual_key =
      case Map.get(@compositions, key) do
        [first | _] -> first
        nil -> key
      end

    case Map.get(@prompts, actual_key) do
      %{metadata: %{version: v}} when is_integer(v) -> v
      %{metadata: _} -> 1
      nil -> raise ArgumentError, "Unknown prompt: #{inspect(key)}. Available: #{inspect(list())}"
    end
  end

  @doc """
  Get full metadata for a prompt.

  Returns a map with metadata keys like `:version`, `:date`, `:changes`.
  For compositions, returns metadata of the first component.

  ## Examples

      iex> meta = PtcRunner.Lisp.Prompts.metadata(:base)
      iex> is_map(meta)
      true

  """
  @spec metadata(atom()) :: map()
  def metadata(key) when is_atom(key) do
    # For compositions, use the first component's metadata
    actual_key =
      case Map.get(@compositions, key) do
        [first | _] -> first
        nil -> key
      end

    case Map.get(@prompts, actual_key) do
      %{metadata: meta} -> meta
      nil -> raise ArgumentError, "Unknown prompt: #{inspect(key)}. Available: #{inspect(list())}"
    end
  end

  @doc """
  Check if a prompt is archived.

  Compositions are never archived.

  ## Examples

      iex> PtcRunner.Lisp.Prompts.archived?(:single_shot)
      false

  """
  @spec archived?(atom()) :: boolean()
  def archived?(key) when is_atom(key) do
    # Compositions are never archived
    if Map.has_key?(@compositions, key) do
      false
    else
      case Map.get(@prompts, key) do
        %{archived: archived} ->
          archived

        nil ->
          raise ArgumentError, "Unknown prompt: #{inspect(key)}. Available: #{inspect(list())}"
      end
    end
  end

  @doc """
  List all available prompt keys (compositions, snippets, and archived).

  ## Examples

      iex> keys = PtcRunner.Lisp.Prompts.list()
      iex> :single_shot in keys
      true
      iex> :multi_turn in keys
      true

  """
  @spec list() :: [atom()]
  def list do
    composition_keys = Map.keys(@compositions)
    snippet_keys = Map.keys(@prompts)
    Enum.uniq(composition_keys ++ snippet_keys)
  end

  @doc """
  List only current (non-archived) prompt keys.

  ## Examples

      iex> keys = PtcRunner.Lisp.Prompts.list_current()
      iex> :single_shot in keys
      true
      iex> :base in keys
      true

  """
  @spec list_current() :: [atom()]
  def list_current do
    composition_keys = Map.keys(@compositions)

    current_snippet_keys =
      @prompts
      |> Enum.filter(fn {_key, %{archived: archived}} -> not archived end)
      |> Enum.map(fn {key, _} -> key end)

    Enum.uniq(composition_keys ++ current_snippet_keys)
  end

  @doc """
  List all prompts with descriptions.

  Returns a list of `{key, description}` tuples for all available prompts.
  Archived prompts have "[archived]" appended to their description.

  ## Examples

      iex> list = PtcRunner.Lisp.Prompts.list_with_descriptions()
      iex> Enum.any?(list, fn {k, _} -> k == :single_shot end)
      true

  """
  @spec list_with_descriptions() :: [{atom(), String.t()}]
  def list_with_descriptions do
    composition_descriptions = [
      {:single_shot, "Base language reference for single-turn queries"},
      {:multi_turn, "Base + memory addon for multi-turn conversations"}
    ]

    snippet_descriptions =
      Enum.map(@prompts, fn {key, %{content: content, archived: archived}} ->
        # Extract first line as description
        desc =
          content
          |> String.split("\n", parts: 2)
          |> List.first()
          |> String.replace(~r/^#\s*/, "")
          |> String.trim()

        suffix = if archived, do: " [archived]", else: ""
        {key, desc <> suffix}
      end)

    composition_descriptions ++ snippet_descriptions
  end
end
