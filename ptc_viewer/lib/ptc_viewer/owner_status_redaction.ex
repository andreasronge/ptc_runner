defmodule PtcViewer.OwnerStatusRedaction do
  @moduledoc false

  @spec format(term()) :: map()
  def format(_status),
    do: %{state: :redacted, message: :redacted, reason: :redacted, log: []}

  @spec format(term(), term()) :: keyword()
  def format(_reason, _status), do: [data: [{~c"State", :redacted}]]
end
