defmodule PtcRunner.SubAgent.Chat do
  @moduledoc """
  Opaque continuation state for `PtcRunner.SubAgent.chat/3`.

  A chat continuation carries conversation messages plus native PTC-Lisp memory.
  Treat it as an opaque handle and pass it back with `chat: chat` on the next
  call. It intentionally has no JSON encoder: persisting native continuation
  state through JSON can corrupt Lisp runtime values such as keywords.
  """

  @opaque t :: %__MODULE__{
            messages: [map()],
            memory: map()
          }

  defstruct messages: [], memory: %{}

  @doc """
  Creates a fresh chat continuation.

  Most callers can omit `:chat` on the first `PtcRunner.SubAgent.chat/3` call
  and pass back the returned handle on later calls. Use `new/0` when an
  application needs an initial continuation value in its own state, such as a
  LiveView socket assign.
  """
  @spec new([map()], map()) :: t()
  def new(messages \\ [], memory \\ %{}) when is_list(messages) and is_map(memory) do
    %__MODULE__{messages: messages, memory: memory}
  end

  @doc false
  @spec messages(t()) :: [map()]
  def messages(%__MODULE__{messages: messages}), do: messages

  @doc false
  @spec memory(t()) :: map()
  def memory(%__MODULE__{memory: memory}), do: memory
end

defimpl Inspect, for: PtcRunner.SubAgent.Chat do
  import Inspect.Algebra

  def inspect(chat, opts) do
    concat([
      "#PtcRunner.SubAgent.Chat<",
      to_doc(%{messages: length(chat.messages), memory: :opaque}, opts),
      ">"
    ])
  end
end
