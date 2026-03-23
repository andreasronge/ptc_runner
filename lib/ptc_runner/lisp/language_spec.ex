defmodule PtcRunner.Lisp.LanguageSpec do
  @moduledoc """
  Language specification compositions for PTC-Lisp.

  Provides pre-composed language specs built from two axes plus optional capabilities:

  - **Behavior axis**: `:single_shot`, `:explicit_return`, `:auto_return`
  - **Reference**: Optional language reference (tool syntax, Java interop, restrictions)
  - **Capabilities**: `:journal` (task caching, semantic progress)

  Compositions do **not** include the language reference by default. Use
  `{:profile, behavior, reference: :full}` to add it for weaker models.

  ## Compositions

  | Key | Description |
  |-----|-------------|
  | `:single_shot` | Last expr = answer, one turn |
  | `:explicit_return` | Multi-turn, must call `(return ...)`/`(fail ...)` |
  | `:auto_return` | Multi-turn, println = continue, no println = answer |
  | `:explicit_journal` | Explicit return + journal (task/step-done) |
  | `:minimal` | Minimal multi-turn for capable models |

  ## Structured Profiles

  For programmatic composition, use `resolve_profile/1` with a tuple:

      # Add language reference for weaker models
      LanguageSpec.resolve_profile({:profile, :explicit_return, reference: :full})

      # Add journal capability
      LanguageSpec.resolve_profile({:profile, :explicit_return, journal: true})

  ## Usage

      # For single-turn queries
      PtcRunner.Lisp.LanguageSpec.get(:single_shot)

      # For multi-turn conversations
      PtcRunner.Lisp.LanguageSpec.get(:explicit_return)

      # Raw snippets for custom compositions
      PtcRunner.Lisp.LanguageSpec.get(:reference) <> my_custom_addon
  """

  alias PtcRunner.Prompts

  # Compositions: predefined combinations of snippets
  # Default compositions do NOT include the language reference.
  # Use {:profile, behavior, reference: :full} to add it for weaker models.
  @compositions %{
    single_shot: [:behavior_single_shot],
    explicit_return: [:behavior_multi_turn, :behavior_return_explicit],
    auto_return: [:behavior_multi_turn, :behavior_return_auto],
    explicit_journal: [
      :behavior_multi_turn,
      :behavior_return_explicit,
      :capability_journal
    ]
    # Note: :minimal is a direct snippet, not a composition (no composition entry needed)
  }

  # Snippet keys mapped to Prompts module functions
  @snippets %{
    reference: :reference,
    behavior_single_shot: :behavior_single_shot,
    behavior_multi_turn: :behavior_multi_turn,
    behavior_return_explicit: :behavior_return_explicit,
    behavior_return_auto: :behavior_return_auto,
    capability_journal: :capability_journal,
    minimal: :minimal
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

  Supports both raw snippets (`:reference`, `:behavior_multi_turn`) and compositions
  (`:single_shot`, `:explicit_return`).

  ## Examples

      iex> prompt = PtcRunner.Lisp.LanguageSpec.get(:single_shot)
      iex> is_binary(prompt)
      true

      iex> prompt = PtcRunner.Lisp.LanguageSpec.get(:explicit_return)
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
  Resolve a structured prompt profile to a composed prompt string.

  Accepts either an atom (delegates to `get!/1`) or a tuple for structured composition:

      # Atom form (existing)
      resolve_profile(:explicit_return)

      # Tuple form with options
      resolve_profile({:profile, :explicit_return, reference: :full, journal: true})

      # Tuple form with defaults (reference: :none, journal: false)
      resolve_profile({:profile, :auto_return})

  ## Options

  - `:reference` - `:none` (default) or `:full`
  - `:journal` - `true` or `false` (default)

  ## Validation

  Raises `ArgumentError` for:
  - Unknown behavior (must be `:single_shot`, `:explicit_return`, or `:auto_return`)
  - `journal: true` with `:single_shot` (single-shot skips the loop)
  - Unknown reference value (must be `:full` or `:none`)
  - Unknown option keys
  """
  @spec resolve_profile(atom() | {:profile, atom()} | {:profile, atom(), keyword()}) ::
          String.t()
  def resolve_profile(profile) when is_atom(profile), do: get!(profile)

  def resolve_profile({:profile, behavior}) do
    resolve_profile({:profile, behavior, []})
  end

  def resolve_profile({:profile, behavior, opts}) do
    validate_profile!(behavior, opts)

    reference = Keyword.get(opts, :reference, :none)
    journal? = Keyword.get(opts, :journal, false)

    parts = if reference == :full, do: [:reference], else: []

    parts =
      parts ++
        case behavior do
          :single_shot -> [:behavior_single_shot]
          :explicit_return -> [:behavior_multi_turn, :behavior_return_explicit]
          :auto_return -> [:behavior_multi_turn, :behavior_return_auto]
        end

    parts = if journal?, do: parts ++ [:capability_journal], else: parts

    parts
    |> Enum.map(&get/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp validate_profile!(behavior, opts) do
    unless behavior in [:single_shot, :explicit_return, :auto_return] do
      raise ArgumentError,
            "Unknown behavior: #{inspect(behavior)}. " <>
              "Expected :single_shot, :explicit_return, or :auto_return"
    end

    if behavior == :single_shot and Keyword.get(opts, :journal, false) do
      raise ArgumentError,
            "journal: true is not compatible with :single_shot behavior (single-shot skips the loop)"
    end

    reference = Keyword.get(opts, :reference, :none)

    unless reference in [:full, :none] do
      raise ArgumentError,
            "Unknown reference: #{inspect(reference)}. Expected :full or :none"
    end

    allowed_keys = [:reference, :journal]
    unknown = Keyword.keys(opts) -- allowed_keys

    unless unknown == [] do
      raise ArgumentError,
            "Unknown profile options: #{inspect(unknown)}. Allowed: #{inspect(allowed_keys)}"
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

      iex> meta = PtcRunner.Lisp.LanguageSpec.metadata(:reference)
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
      iex> :explicit_return in keys
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
      {:single_shot, "Single-shot (last expr = answer)"},
      {:explicit_return, "Multi-turn + explicit return (return/fail required)"},
      {:auto_return, "Multi-turn + auto return (println to explore, last expr to answer)"},
      {:explicit_journal, "Multi-turn + explicit return + journal (task/step-done)"}
    ]

    # Snippets that are not also compositions get auto-described from content
    composition_keys = Map.keys(@compositions)

    snippet_descriptions =
      @snippets
      |> Enum.reject(fn {key, _} -> key in composition_keys end)
      |> Enum.map(fn {key, prompts_key} ->
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
