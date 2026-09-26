defmodule PtcRunner.Kernel.ModelCapabilities do
  @moduledoc """
  Classifies reserved model-call capability names for Kernel policy.

  Model calls share request hashing, reservation, spend, deadlines, and
  inspection handling. Chat calls additionally use the LLM router, structured
  output schemas, conversation turns, and chat-only counters.

  Trusted callers may supply additional model-call names for one dispatch or
  inspection assembly. The default classification remains fixed by reserved
  name and does not use process-global state.
  """

  @chat_name "llm-request"
  @future_model_names ["decision-request"]
  @model_sources %{llm: @chat_name, llm_replay: @chat_name}

  @spec model_call_name(atom()) :: binary() | nil
  def model_call_name(source), do: Map.get(@model_sources, source)

  @spec model_call?(term()) :: boolean()
  def model_call?(name), do: chat?(name)

  @doc "Classifies a name with extra model-call names supplied by a trusted caller."
  @spec model_call?(term(), [binary()]) :: boolean()
  def model_call?(name, extra_names) when is_list(extra_names) do
    model_call?(name) or Enum.any?(extra_names, &same_name?(&1, name))
  end

  defp same_name?(left, right) when is_binary(left) and is_binary(right), do: left == right

  defp same_name?(left, right) when is_binary(left) and is_atom(right),
    do: left == Atom.to_string(right)

  defp same_name?(_left, _right), do: false

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
