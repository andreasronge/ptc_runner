defmodule PtcRunner.Kernel.ModelCapabilities do
  @moduledoc """
  Classifies reserved model-call capability names for Kernel policy.

  Model calls share request hashing, reservation, spend, deadlines, and
  inspection handling. Chat calls additionally use the LLM router, structured
  output schemas, conversation turns, and chat-only counters.
  """

  @chat_name "llm-request"
  @future_model_names ["decision-request"]
  @model_sources %{llm: @chat_name, llm_replay: @chat_name}

  @spec model_call_name(atom()) :: binary() | nil
  def model_call_name(source), do: Map.get(@model_sources, source)

  @spec model_call?(term()) :: boolean()
  def model_call?(name), do: chat?(name)

  @doc "Returns whether a name is reserved for current or future model calls."
  @spec reserved_name?(term()) :: boolean()
  def reserved_name?(name) when is_atom(name), do: reserved_name?(Atom.to_string(name))
  def reserved_name?(name) when is_binary(name), do: chat?(name) or name in @future_model_names
  def reserved_name?(_name), do: false

  @spec chat?(term()) :: boolean()
  def chat?(name) when is_binary(name), do: name == @chat_name
  def chat?(name) when is_atom(name), do: Atom.to_string(name) == @chat_name
  def chat?(_name), do: false
end
