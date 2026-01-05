defmodule PtcDemo.Prompts do
  @moduledoc """
  Prompt profiles for testing different LLM instruction styles.

  This module delegates to `PtcRunner.Lisp.Prompts` for standard prompts
  and provides demo-specific extensions.

  Different prompts can be useful for:
  - Testing model capabilities with varying levels of detail
  - Benchmarking token usage vs accuracy tradeoffs
  - Single-shot queries vs multi-turn conversations
  - Model-specific optimizations (some models need more/less detail)

  ## Available Profiles

  | Profile | Description | Use Case |
  |---------|-------------|----------|
  | `:single_shot` | Base language reference | Quick lookups, no memory |
  | `:multi_turn` | Base + memory addon | Conversational analysis |
  | `:multi_turn_full` | Multi-turn with extra workflow guidance | Complex sessions |

  ## Usage

      # In test runner
      PtcDemo.LispTestRunner.run_all(prompt: :single_shot)

      # In agent
      PtcDemo.Agent.start_link(prompt: :multi_turn)

      # List available profiles
      PtcDemo.Prompts.list()
  """

  alias PtcRunner.Lisp.Prompts, as: LibPrompts

  @doc """
  Get a prompt profile by name.

  ## Parameters

  - `profile` - Atom identifying the prompt profile (default: `:single_shot`)

  ## Returns

  A string containing the language specification prompt.

  ## Examples

      iex> prompt = PtcDemo.Prompts.get(:single_shot)
      iex> String.contains?(prompt, "PTC-Lisp")
      true

  """
  @spec get(atom()) :: String.t()
  def get(profile \\ :single_shot)

  # Delegate standard prompts to the library
  def get(profile) when profile in [:single_shot, :multi_turn, :base, :addon_memory] do
    LibPrompts.get(profile)
  end

  # Demo-specific: multi-turn with extra workflow guidance
  def get(:multi_turn_full) do
    """
    #{LibPrompts.get(:multi_turn)}

    ## Multi-Turn Workflow

    You are in a conversational session. Use memory to build up analysis:

    **Turn 1: Store intermediate results**
    ```clojure
    {:filtered-data (->> ctx/orders (filter (where :status = "complete")))}
    ```

    **Turn 2: Reference previous results**
    ```clojure
    {:summary {:count (count filtered-data)
               :total (sum-by :amount filtered-data)}
     :return "Analysis complete"}
    ```

    **Memory Contract:**
    - Return a map → keys merge into memory
    - Include `:return` key → that value is shown to user
    - Non-map return → shown directly, no memory update

    Build your analysis step by step, storing intermediate results for later reference.
    """
  end

  @doc """
  List all available prompt profiles with descriptions.

  ## Returns

  A list of `{profile_name, description}` tuples.

  ## Examples

      iex> profiles = PtcDemo.Prompts.list()
      iex> Enum.find(profiles, fn {name, _} -> name == :single_shot end)
      {:single_shot, "Base language reference for single-turn queries"}

  """
  @spec list() :: [{atom(), String.t()}]
  def list do
    [
      {:single_shot, "Base language reference for single-turn queries"},
      {:multi_turn, "Base + memory addon for multi-turn conversations"},
      {:multi_turn_full, "Multi-turn with extra workflow guidance"}
    ]
  end

  @doc """
  Get the names of all available profiles.

  ## Examples

      iex> :single_shot in PtcDemo.Prompts.profiles()
      true

  """
  @spec profiles() :: [atom()]
  def profiles do
    Enum.map(list(), fn {name, _} -> name end)
  end

  @doc """
  Validate a prompt profile name string and convert to atom.

  ## Examples

      iex> PtcDemo.Prompts.validate_profile("single_shot")
      {:ok, :single_shot}

      iex> PtcDemo.Prompts.validate_profile("invalid")
      {:error, "Unknown prompt profile 'invalid'. Valid: single_shot, multi_turn, multi_turn_full"}

  """
  @spec validate_profile(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def validate_profile(profile_str) when is_binary(profile_str) do
    known_profiles = Enum.map(profiles(), &Atom.to_string/1)

    if profile_str in known_profiles do
      {:ok, String.to_existing_atom(profile_str)}
    else
      valid = Enum.join(profiles(), ", ")
      {:error, "Unknown prompt profile '#{profile_str}'. Valid: #{valid}"}
    end
  end

  @doc """
  Get the version number for a prompt profile.

  Delegates to library for standard prompts. Demo-specific prompts return 1.

  ## Examples

      iex> PtcDemo.Prompts.version(:single_shot)
      1

  """
  @spec version(atom()) :: pos_integer()
  def version(:multi_turn_full), do: 1
  def version(profile), do: LibPrompts.version(profile)

  @doc """
  Get metadata for a prompt profile.

  Delegates to library for standard prompts. Demo-specific prompts return minimal metadata.

  ## Examples

      iex> meta = PtcDemo.Prompts.metadata(:single_shot)
      iex> is_map(meta)
      true

  """
  @spec metadata(atom()) :: map()
  def metadata(:multi_turn_full), do: %{version: 1, type: :demo}
  def metadata(profile), do: LibPrompts.metadata(profile)

  @doc """
  Check if a prompt profile is archived.

  Demo-specific prompts are never archived.

  ## Examples

      iex> PtcDemo.Prompts.archived?(:single_shot)
      false

  """
  @spec archived?(atom()) :: boolean()
  def archived?(:multi_turn_full), do: false
  def archived?(profile), do: LibPrompts.archived?(profile)

  @doc """
  List only current (non-archived) prompt profiles.

  ## Examples

      iex> keys = PtcDemo.Prompts.list_current()
      iex> :single_shot in keys
      true

  """
  @spec list_current() :: [atom()]
  def list_current do
    # All demo prompts are current, plus library's current prompts
    demo_prompts = [:multi_turn_full]
    lib_current = LibPrompts.list_current()
    Enum.uniq(lib_current ++ demo_prompts)
  end
end
