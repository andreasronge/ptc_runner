defmodule PtcRunner.Kernel.ExplicitFailureDiagnostic do
  @moduledoc false

  # A workflow that ends in `(fail value)` reports the outcome, never the
  # value: the value is arbitrary application data, and canonical events and
  # the command envelope are payload-free by construction. What the caller
  # does need is where the value went, because the retention outcomes are
  # otherwise indistinguishable from the exit status. Each is one closed
  # literal, so the message adds no caller-supplied text.

  @retained "the workflow signalled an explicit failure; its value is retained in the run's private inspection record"
  @unrequested "the workflow signalled an explicit failure; its value was not retained because the run published no inspection artifact — set artifacts.inspection in the project configuration, or pass --inspect FILE"
  @unwritten "the workflow signalled an explicit failure; its value was not retained because the run's inspection artifact did not reach its destination"
  @oversized "the workflow signalled an explicit failure; its value was not retained because it exceeded the terminal result ceiling"
  @unrepresentable "the workflow signalled an explicit failure; its value was not retained because it cannot be represented as JSON"

  @messages %{
    retained: @retained,
    unrequested: @unrequested,
    unwritten: @unwritten,
    oversized: @oversized,
    unrepresentable: @unrepresentable
  }

  @type retention ::
          :retained | :unrequested | :unwritten | :oversized | :unrepresentable

  @spec retentions() :: [retention()]
  def retentions, do: Map.keys(@messages)

  @spec retention?(term()) :: boolean()
  def retention?(retention), do: is_map_key(@messages, retention)

  @spec message(term()) :: {:ok, binary()} | :error
  def message(retention), do: Map.fetch(@messages, retention)

  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message),
    do: message in Map.values(@messages)

  def valid_message?(_message), do: false

  @spec message_schema(binary()) :: map()
  def message_schema(fallback),
    do: %{"enum" => Enum.sort([fallback | Map.values(@messages)])}
end
