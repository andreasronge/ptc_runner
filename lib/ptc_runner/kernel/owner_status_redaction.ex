defmodule PtcRunner.Kernel.OwnerStatusRedaction do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
        @impl GenServer
        def format_status(_status),
          do: %{state: :redacted, message: :redacted, reason: :redacted, log: []}
      else
        def format_status(_status),
          do: %{state: :redacted, message: :redacted, reason: :redacted, log: []}
      end

      @impl GenServer
      def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]
    end
  end
end
