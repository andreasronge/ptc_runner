defmodule GitQuery.Config do
  @moduledoc """
  Configuration for the git query pipeline.

  Supports four presets with different trade-offs:
  - `:simple` - No planning, pass all context (baseline)
  - `:planned` - Always plan, selective context
  - `:adaptive` - LLM decides if planning needed
  - `:multi_turn` - Allow retries within steps
  """

  defstruct [
    # :never | :always | :auto
    :planning,
    # :all | :declared | :summary
    :context_mode,
    # 1 = single-shot, >1 = allow retries
    :max_turns,
    # :full | :summary | :constraints
    :anchor_mode
  ]

  @type t :: %__MODULE__{
          planning: :never | :always | :auto,
          context_mode: :all | :declared | :summary,
          max_turns: pos_integer(),
          anchor_mode: :full | :summary | :constraints
        }

  @doc """
  Get a preset configuration by name.

  ## Examples

      iex> GitQuery.Config.preset(:simple)
      %GitQuery.Config{planning: :never, context_mode: :all, max_turns: 3, anchor_mode: :full}

      iex> GitQuery.Config.preset(:adaptive)
      %GitQuery.Config{planning: :auto, context_mode: :declared, max_turns: 3, anchor_mode: :constraints}
  """
  @spec preset(atom()) :: t()
  def preset(:simple) do
    %__MODULE__{
      planning: :never,
      context_mode: :all,
      # Tool-using agents need at least 2 turns (call tools + return)
      max_turns: 3,
      anchor_mode: :full
    }
  end

  def preset(:planned) do
    %__MODULE__{
      planning: :always,
      context_mode: :declared,
      max_turns: 3,
      anchor_mode: :full
    }
  end

  def preset(:adaptive) do
    %__MODULE__{
      planning: :auto,
      context_mode: :declared,
      max_turns: 3,
      anchor_mode: :constraints
    }
  end

  def preset(:multi_turn) do
    %__MODULE__{
      planning: :auto,
      context_mode: :all,
      max_turns: 3,
      anchor_mode: :full
    }
  end

  @doc """
  List all available preset names.

  ## Examples

      iex> GitQuery.Config.preset_names()
      [:adaptive, :multi_turn, :planned, :simple]
  """
  @spec preset_names() :: [atom()]
  def preset_names do
    [:adaptive, :multi_turn, :planned, :simple]
  end
end
