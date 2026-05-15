defmodule PtcRunner.Lisp.PromptRegistry do
  @moduledoc false

  alias PtcRunner.Prompts

  @common_card %{
    audience: :subagent_system_prompt,
    budget_profile: :standard,
    dynamic_boundary: :static_card,
    trust: :authoritative
  }

  @cards %{
    reference:
      Map.merge(@common_card, %{
        id: :reference,
        dimensions: [:dialect, :trust_boundary],
        placement: :dialect_reference,
        prompt_fun: :reference,
        surface: :subagent_content
      }),
    behavior_single_shot:
      Map.merge(@common_card, %{
        id: :behavior_single_shot,
        dimensions: [:completion_contract],
        placement: :completion_contract,
        prompt_fun: :behavior_single_shot,
        surface: :subagent_content
      }),
    behavior_multi_turn:
      Map.merge(@common_card, %{
        id: :behavior_multi_turn,
        dimensions: [:execution_surface],
        placement: :execution_guidance,
        prompt_fun: :behavior_multi_turn,
        surface: :subagent_content
      }),
    behavior_return_explicit:
      Map.merge(@common_card, %{
        id: :behavior_return_explicit,
        dimensions: [:completion_contract],
        placement: :completion_contract,
        prompt_fun: :behavior_return_explicit,
        surface: :subagent_content
      }),
    capability_journal:
      Map.merge(@common_card, %{
        id: :capability_journal,
        dimensions: [:capability],
        placement: :capability_addon,
        prompt_fun: :capability_journal,
        surface: :subagent_content
      })
  }

  @profiles %{
    single_shot: [:reference, :behavior_single_shot],
    explicit_return: [:reference, :behavior_multi_turn, :behavior_return_explicit],
    explicit_journal: [
      :reference,
      :behavior_multi_turn,
      :behavior_return_explicit,
      :capability_journal
    ]
  }

  @doc false
  @spec render(atom()) :: String.t() | nil
  def render(key) when is_atom(key) do
    cond do
      Map.has_key?(@profiles, key) ->
        key
        |> profile_parts!()
        |> render_parts()

      Map.has_key?(@cards, key) ->
        render_card(key)

      true ->
        nil
    end
  end

  @doc false
  @spec render_structured(atom(), keyword()) :: String.t()
  def render_structured(behavior, opts) when is_atom(behavior) and is_list(opts) do
    reference = Keyword.get(opts, :reference, :full)
    journal? = Keyword.get(opts, :journal, false)

    parts = if reference == :full, do: [:reference], else: []

    parts =
      parts ++
        case behavior do
          :single_shot -> [:behavior_single_shot]
          :explicit_return -> [:behavior_multi_turn, :behavior_return_explicit]
        end

    parts = if journal?, do: parts ++ [:capability_journal], else: parts

    render_parts(parts)
  end

  @doc false
  @spec render_parts([atom()]) :: String.t()
  def render_parts(parts) when is_list(parts) do
    Enum.map_join(parts, "\n\n", &render_card/1)
  end

  @doc false
  @spec card_metadata(atom()) :: map() | nil
  def card_metadata(key) when is_atom(key) do
    case Map.get(@cards, key) do
      nil -> nil
      card -> Map.delete(card, :prompt_fun)
    end
  end

  @doc false
  @spec profile_metadata(atom()) :: [map()] | nil
  def profile_metadata(key) when is_atom(key) do
    case Map.get(@profiles, key) do
      nil -> nil
      parts -> Enum.map(parts, &card_metadata/1)
    end
  end

  @doc false
  @spec prompt_header(atom()) :: {String.t(), String.t()} | nil
  def prompt_header(key) when is_atom(key) do
    with %{prompt_fun: prompt_fun} <- Map.get(@cards, first_card_key(key)) do
      header_fun = String.to_atom("#{prompt_fun}_with_header")
      apply(Prompts, header_fun, [])
    end
  end

  @doc false
  @spec first_card_key(atom()) :: atom() | nil
  def first_card_key(key) when is_atom(key) do
    case Map.get(@profiles, key) do
      [first | _] -> first
      nil -> if Map.has_key?(@cards, key), do: key
    end
  end

  @doc false
  @spec prompt_keys() :: [atom()]
  def prompt_keys do
    Enum.uniq(profile_keys() ++ card_keys())
  end

  @doc false
  @spec profile_keys() :: [atom()]
  def profile_keys, do: Map.keys(@profiles)

  @doc false
  @spec card_keys() :: [atom()]
  def card_keys, do: Map.keys(@cards)

  @doc false
  @spec profile_parts!(atom()) :: [atom()]
  def profile_parts!(key) when is_atom(key), do: Map.fetch!(@profiles, key)

  defp render_card(key) do
    %{prompt_fun: prompt_fun} = Map.fetch!(@cards, key)
    apply(Prompts, prompt_fun, [])
  end
end
