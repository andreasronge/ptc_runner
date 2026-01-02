defmodule PtcRunner.Lisp.Prompts do
  @moduledoc """
  Prompt loader for PTC-Lisp language references.

  Loads prompt variants from `priv/prompts/` directory at compile time.
  Each prompt file follows the naming convention `lisp-{name}.md` where
  `{name}` becomes the atom key (with hyphens converted to underscores).

  ## Available Prompts

  | Key | File | Use Case |
  |-----|------|----------|
  | `:default` | `lisp-default.md` | Full reference (alias for Schema.to_prompt) |
  | `:minimal` | `lisp-minimal.md` | Token-efficient, simple queries |
  | `:single_shot` | `lisp-single-shot.md` | One-turn queries with examples |

  ## Archived Prompts

  Old versions are stored in `priv/prompts/archive/` with versioned filenames:

      priv/prompts/archive/lisp-minimal-v1.md -> :minimal_v1

  Use `list_current/0` to get only current prompts, or `list/0` for all.

  ## Version Metadata

  Prompt files can include optional metadata headers:

      <!-- version: 2 -->
      <!-- date: 2025-01-15 -->
      <!-- changes: Removed threading examples -->

  Access metadata via `version/1` and `metadata/1`.

  ## Usage

      # Get a specific prompt
      PtcRunner.Lisp.Prompts.get(:minimal)

      # List available prompts
      PtcRunner.Lisp.Prompts.list()

      # List only current (non-archived) prompts
      PtcRunner.Lisp.Prompts.list_current()

      # Get version info
      PtcRunner.Lisp.Prompts.version(:minimal)  #=> 1

      # Use in SubAgent
      SubAgent.new(
        prompt: "...",
        system_prompt: %{language_spec: PtcRunner.Lisp.Prompts.get(:minimal)}
      )
  """

  alias PtcRunner.Lisp.Schema

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

  # Load all prompts at compile time (current prompts)
  @current_prompts (fn ->
                      @prompt_files
                      |> Enum.map(fn path ->
                        filename = Path.basename(path, ".md")

                        key =
                          filename
                          |> String.replace_prefix("lisp-", "")
                          |> String.replace("-", "_")
                          |> String.to_atom()

                        file_content = File.read!(path)

                        content =
                          case String.split(file_content, "<!-- PTC_PROMPT_START -->") do
                            [_before, after_start] ->
                              case String.split(after_start, "<!-- PTC_PROMPT_END -->") do
                                [prompt_text, _after_end] ->
                                  String.trim(prompt_text)

                                _ ->
                                  String.trim(after_start)
                              end

                            _ ->
                              String.trim(file_content)
                          end

                        # Inline metadata parsing
                        header =
                          case String.split(file_content, "<!-- PTC_PROMPT_START -->") do
                            [before, _rest] -> before
                            _ -> file_content
                          end

                        metadata_regex = ~r/<!--\s*(\w+):\s*(.+?)\s*-->/

                        metadata =
                          Regex.scan(metadata_regex, header)
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

                        {key, %{content: content, metadata: metadata, archived: false}}
                      end)
                      |> Map.new()
                    end).()

  # Load archived prompts
  @archived_prompts (fn ->
                       @archive_files
                       |> Enum.map(fn path ->
                         filename = Path.basename(path, ".md")

                         key =
                           filename
                           |> String.replace_prefix("lisp-", "")
                           |> String.replace("-", "_")
                           |> String.to_atom()

                         file_content = File.read!(path)

                         content =
                           case String.split(file_content, "<!-- PTC_PROMPT_START -->") do
                             [_before, after_start] ->
                               case String.split(after_start, "<!-- PTC_PROMPT_END -->") do
                                 [prompt_text, _after_end] ->
                                   String.trim(prompt_text)

                                 _ ->
                                   String.trim(after_start)
                               end

                             _ ->
                               String.trim(file_content)
                           end

                         # Inline metadata parsing
                         header =
                           case String.split(file_content, "<!-- PTC_PROMPT_START -->") do
                             [before, _rest] -> before
                             _ -> file_content
                           end

                         metadata_regex = ~r/<!--\s*(\w+):\s*(.+?)\s*-->/

                         metadata =
                           Regex.scan(metadata_regex, header)
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

                         {key, %{content: content, metadata: metadata, archived: true}}
                       end)
                       |> Map.new()
                     end).()

  # Combined prompts (current + archived)
  @prompts Map.merge(@current_prompts, @archived_prompts)

  @doc """
  Get a prompt by key.

  ## Parameters

  - `key` - Atom identifying the prompt (e.g., `:minimal`, `:single_shot`)

  ## Returns

  The prompt content as a string.

  ## Examples

      iex> prompt = PtcRunner.Lisp.Prompts.get(:default)
      iex> is_binary(prompt)
      true

  """
  @spec get(atom()) :: String.t() | nil
  def get(:default) do
    # Default is the full reference from Schema
    Schema.to_prompt()
  end

  def get(key) when is_atom(key) do
    case Map.get(@prompts, key) do
      %{content: content} -> content
      nil -> nil
    end
  end

  @doc """
  Get a prompt by key, raising if not found.

  ## Examples

      iex> prompt = PtcRunner.Lisp.Prompts.get!(:default)
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

  ## Examples

      iex> PtcRunner.Lisp.Prompts.version(:default)
      1

  """
  @spec version(atom()) :: pos_integer()
  def version(:default), do: 1

  def version(key) when is_atom(key) do
    case Map.get(@prompts, key) do
      %{metadata: %{version: v}} when is_integer(v) -> v
      %{metadata: _} -> 1
      nil -> raise ArgumentError, "Unknown prompt: #{inspect(key)}. Available: #{inspect(list())}"
    end
  end

  @doc """
  Get full metadata for a prompt.

  Returns a map with metadata keys like `:version`, `:date`, `:changes`.

  ## Examples

      iex> meta = PtcRunner.Lisp.Prompts.metadata(:default)
      iex> is_map(meta)
      true

  """
  @spec metadata(atom()) :: map()
  def metadata(:default), do: %{version: 1}

  def metadata(key) when is_atom(key) do
    case Map.get(@prompts, key) do
      %{metadata: meta} -> meta
      nil -> raise ArgumentError, "Unknown prompt: #{inspect(key)}. Available: #{inspect(list())}"
    end
  end

  @doc """
  Check if a prompt is archived.

  ## Examples

      iex> PtcRunner.Lisp.Prompts.archived?(:default)
      false

  """
  @spec archived?(atom()) :: boolean()
  def archived?(:default), do: false

  def archived?(key) when is_atom(key) do
    case Map.get(@prompts, key) do
      %{archived: archived} -> archived
      nil -> raise ArgumentError, "Unknown prompt: #{inspect(key)}. Available: #{inspect(list())}"
    end
  end

  @doc """
  List all available prompt keys (current and archived).

  ## Examples

      iex> keys = PtcRunner.Lisp.Prompts.list()
      iex> :default in keys
      true

  """
  @spec list() :: [atom()]
  def list do
    [:default | Map.keys(@prompts)]
  end

  @doc """
  List only current (non-archived) prompt keys.

  ## Examples

      iex> keys = PtcRunner.Lisp.Prompts.list_current()
      iex> :default in keys
      true
      iex> :minimal in keys
      true

  """
  @spec list_current() :: [atom()]
  def list_current do
    current_keys =
      @prompts
      |> Enum.filter(fn {_key, %{archived: archived}} -> not archived end)
      |> Enum.map(fn {key, _} -> key end)

    [:default | current_keys]
  end

  @doc """
  List all prompts with descriptions.

  Returns a list of `{key, description}` tuples.
  """
  @spec list_with_descriptions() :: [{atom(), String.t()}]
  def list_with_descriptions do
    [
      {:default, "Full PTC-Lisp reference - comprehensive documentation"}
      | Enum.map(@prompts, fn {key, %{content: content, archived: archived}} ->
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
    ]
  end
end
