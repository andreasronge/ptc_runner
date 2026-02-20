defmodule PtcRunner.Lisp.LanguageSpec do
  @moduledoc """
  Language specification compositions for PTC-Lisp.

  Provides pre-composed language specs for common use cases. Raw prompts are
  loaded via `PtcRunner.Prompts`.

  ## Available Specs

  | Key | Description |
  |-----|-------------|
  | `:single_shot` | Base + single-shot rules |
  | `:multi_turn` | Base + multi-turn rules (return/fail, memory) |
  | `:multi_turn_journal` | Base + multi-turn + journal (task/step-done) |

  ## Raw Snippets

  | Key | Description |
  |-----|-------------|
  | `:base` | Core language reference |
  | `:addon_single_shot` | Single-shot mode rules |
  | `:addon_multi_turn` | Multi-turn mode rules |
  | `:addon_journal` | Journal, task caching, semantic progress |

  ## Version Metadata

  Spec files include metadata headers:

      <!-- version: 2 -->
      <!-- date: 2025-01-15 -->
      <!-- changes: Removed threading examples -->

  Access metadata via `version/1` and `metadata/1`.

  ## Usage

      # For single-turn queries
      PtcRunner.Lisp.LanguageSpec.get(:single_shot)

      # For multi-turn conversations
      PtcRunner.Lisp.LanguageSpec.get(:multi_turn)

      # Raw snippets for custom compositions
      PtcRunner.Lisp.LanguageSpec.get(:base) <> my_custom_addon
  """

  alias PtcRunner.Prompts

  # Compositions: predefined combinations of snippets
  @compositions %{
    single_shot: [:base, :addon_single_shot],
    multi_turn: [:base, :addon_multi_turn],
    multi_turn_journal: [:base, :addon_multi_turn, :addon_journal]
  }

  # Snippet keys mapped to Prompts module functions
  @snippets %{
    base: :lisp_base,
    addon_single_shot: :lisp_addon_single_shot,
    addon_multi_turn: :lisp_addon_multi_turn,
    addon_journal: :lisp_addon_journal
  }

  # Parse metadata from file header
  defp parse_metadata(header) do
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

  @doc """
  Get a prompt by key.

  Supports both raw snippets (`:base`, `:addon_single_shot`) and compositions
  (`:single_shot`, `:multi_turn`).

  ## Examples

      iex> prompt = PtcRunner.Lisp.LanguageSpec.get(:single_shot)
      iex> is_binary(prompt)
      true

      iex> prompt = PtcRunner.Lisp.LanguageSpec.get(:multi_turn)
      iex> String.contains?(prompt, "<state>")
      true

  """
  @spec get(atom()) :: String.t() | nil
  def get(key) when is_atom(key) do
    case Map.get(@compositions, key) do
      nil ->
        # Direct snippet lookup
        case Map.get(@snippets, key) do
          nil -> nil
          prompts_key -> apply(Prompts, prompts_key, [])
        end

      parts ->
        # Compose from parts
        parts
        |> Enum.map(&get/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")
    end
  end

  @doc """
  Get a prompt by key, raising if not found.

  ## Examples

      iex> prompt = PtcRunner.Lisp.LanguageSpec.get!(:single_shot)
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
  """
  @spec version(atom()) :: pos_integer()
  def version(key) when is_atom(key) do
    actual_key =
      case Map.get(@compositions, key) do
        [first | _] -> first
        nil -> key
      end

    case Map.get(@snippets, actual_key) do
      nil ->
        raise ArgumentError, "Unknown prompt: #{inspect(key)}. Available: #{inspect(list())}"

      prompts_key ->
        header_fn = String.to_atom("#{prompts_key}_with_header")
        {header, _content} = apply(Prompts, header_fn, [])
        meta = parse_metadata(header)
        Map.get(meta, :version, 1)
    end
  end

  @doc """
  Get full metadata for a prompt.

  Returns a map with metadata keys like `:version`, `:date`, `:changes`.
  For compositions, returns metadata of the first component.

  ## Examples

      iex> meta = PtcRunner.Lisp.LanguageSpec.metadata(:base)
      iex> is_map(meta)
      true

  """
  @spec metadata(atom()) :: map()
  def metadata(key) when is_atom(key) do
    actual_key =
      case Map.get(@compositions, key) do
        [first | _] -> first
        nil -> key
      end

    case Map.get(@snippets, actual_key) do
      nil ->
        raise ArgumentError, "Unknown prompt: #{inspect(key)}. Available: #{inspect(list())}"

      prompts_key ->
        header_fn = String.to_atom("#{prompts_key}_with_header")
        {header, _content} = apply(Prompts, header_fn, [])
        parse_metadata(header)
    end
  end

  @doc """
  List all available prompt keys.

  ## Examples

      iex> keys = PtcRunner.Lisp.LanguageSpec.list()
      iex> :single_shot in keys
      true
      iex> :multi_turn in keys
      true

  """
  @spec list() :: [atom()]
  def list do
    composition_keys = Map.keys(@compositions)
    snippet_keys = Map.keys(@snippets)
    Enum.uniq(composition_keys ++ snippet_keys)
  end

  @doc """
  List all prompts with descriptions.

  Returns a list of `{key, description}` tuples.

  ## Examples

      iex> list = PtcRunner.Lisp.LanguageSpec.list_with_descriptions()
      iex> Enum.any?(list, fn {k, _} -> k == :single_shot end)
      true

  """
  @spec list_with_descriptions() :: [{atom(), String.t()}]
  def list_with_descriptions do
    composition_descriptions = [
      {:single_shot, "Base + single-shot rules"},
      {:multi_turn, "Base + multi-turn rules (return/fail, memory)"},
      {:multi_turn_journal, "Base + multi-turn + journal (task/step-done)"}
    ]

    snippet_descriptions =
      Enum.map(@snippets, fn {key, prompts_key} ->
        content = apply(Prompts, prompts_key, [])

        desc =
          content
          |> String.split("\n", parts: 2)
          |> List.first()
          |> String.replace(~r/^#\s*/, "")
          |> String.trim()

        {key, desc}
      end)

    composition_descriptions ++ snippet_descriptions
  end
end
