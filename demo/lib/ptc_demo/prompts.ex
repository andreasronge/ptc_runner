defmodule PtcDemo.Prompts do
  @moduledoc """
  Prompt profiles for testing different LLM instruction styles.

  This module delegates to `PtcRunner.Lisp.LanguageSpec` for standard language specs.

  ## Available Profiles

  | Profile | Description |
  |---------|-------------|
  | `:single_shot` | Reference + single-shot (last expr = answer) |
  | `:explicit_return` | Reference + multi-turn + explicit return |
  | `:auto_return` | Reference + multi-turn + auto return |
  | `:explicit_journal` | Reference + multi-turn + explicit return + journal |
  | `:repl` | REPL mode (standalone) |
  | `:explicit_return_lite` | Multi-turn + explicit return (no reference) |
  | `:auto_return_lite` | Multi-turn + auto return (no reference) |

  ## Usage

      # In test runner
      PtcDemo.LispTestRunner.run_all(prompt: :single_shot)

      # In agent
      PtcDemo.Agent.start_link(prompt: :explicit_return)

      # List available profiles
      PtcDemo.Prompts.list()
  """

  alias PtcRunner.Lisp.LanguageSpec, as: LibLanguageSpec

  @doc """
  Get a prompt profile by name.

  ## Parameters

  - `profile` - Atom identifying the prompt profile (default: `:single_shot`)

  ## Returns

  A string containing the language specification prompt.

  ## Examples

      iex> prompt = PtcDemo.Prompts.get(:single_shot)
      iex> String.contains?(prompt, "<role>")
      true

  """
  @spec get(atom()) :: String.t()
  def get(profile \\ :single_shot)

  # Delegate standard prompts to the library
  def get(profile)
      when profile in [
             :single_shot,
             :single_shot_lite,
             :explicit_return,
             :explicit_return_lite,
             :auto_return,
             :auto_return_lite,
             :explicit_journal,
             :repl,
             :reference
           ] do
    LibLanguageSpec.get(profile)
  end

  @doc """
  List all available prompt profiles with descriptions.

  ## Returns

  A list of `{profile_name, description}` tuples.

  ## Examples

      iex> profiles = PtcDemo.Prompts.list()
      iex> Enum.find(profiles, fn {name, _} -> name == :single_shot end)
      {:single_shot, "Reference + single-shot (last expr = answer)"}

  """
  @spec list() :: [{atom(), String.t()}]
  def list do
    [
      {:single_shot, "Reference + single-shot (last expr = answer)"},
      {:explicit_return, "Reference + multi-turn + explicit return (return/fail required)"},
      {:auto_return, "Reference + multi-turn + auto return (println to explore)"},
      {:explicit_journal, "Reference + multi-turn + explicit return + journal"},
      {:repl, "REPL mode (one expression per turn, incremental exploration)"},
      {:explicit_return_lite, "Multi-turn + explicit return (no reference)"},
      {:auto_return_lite, "Multi-turn + auto return (no reference)"}
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
      {:error, "Unknown prompt profile 'invalid'. Valid: single_shot, explicit_return, auto_return, explicit_journal, repl, explicit_return_lite, auto_return_lite"}

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

  Delegates to library.

  ## Examples

      iex> PtcDemo.Prompts.version(:single_shot)
      1

  """
  @spec version(atom()) :: pos_integer()
  def version(profile) do
    LibLanguageSpec.version(profile)
  end

  @doc """
  Get metadata for a prompt profile.

  Delegates to library for standard profiles, returns empty map for custom ones.

  ## Examples

      iex> meta = PtcDemo.Prompts.metadata(:single_shot)
      iex> is_map(meta)
      true

  """
  @spec metadata(atom()) :: map()
  def metadata(profile) do
    LibLanguageSpec.metadata(profile)
  end
end
