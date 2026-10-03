defmodule PtcRunner.Kernel.LimitConfigurationDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.LimitConfiguration
  alias PtcRunner.Kernel.Limits

  @prefix "normal_event_bytes effective limit "
  @required_middle " is below the required "
  @payload_middle " bytes for event_payload_bytes "
  @suffix "; raise limits.normal_event_bytes, and its installed host ceiling if it is lower, or lower limits.event_payload_bytes"
  @limit_pattern "(?:[1-9][0-9]{0,8}|1[0-9]{9}|2[0-4][0-9]{8}|25[0-8][0-9]{7}|259[0-1][0-9]{6}|2592000000)"
  @required_pattern "[1-9][0-9]{0,9}"
  @maximum_message_bytes byte_size(@prefix) + 10 + byte_size(@required_middle) + 10 +
                           byte_size(@payload_middle) + 10 + byte_size(@suffix)

  @template [
    {:literal, @prefix},
    {:slot, :bytes, :integer, @limit_pattern},
    {:literal, @required_middle},
    {:slot, :required, :integer, @required_pattern},
    {:literal, @payload_middle},
    {:slot, :payload, :integer, @limit_pattern},
    {:literal, @suffix}
  ]

  @doc false
  @spec message(term(), term(), term()) :: {:ok, binary()} | :error
  def message(bytes, required, payload) do
    with {:ok, bytes_row} <- LimitCatalog.fetch(:normal_event_bytes),
         true <- LimitCatalog.valid_value?(bytes_row, bytes),
         {:ok, payload_row} <- LimitCatalog.fetch(:event_payload_bytes),
         true <- LimitCatalog.valid_value?(payload_row, payload),
         {:ok, limits} <- Limits.new(event_payload_bytes: payload),
         true <-
           required in [
             LimitConfiguration.required_normal_event_bytes(limits),
             LimitConfiguration.required_private_event_bytes(limits)
           ],
         true <- bytes < required do
      {:ok,
       DiagnosticPattern.render(@template, %{bytes: bytes, required: required, payload: payload})}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message),
    do:
      DiagnosticPattern.valid_template?(@template, message, fn values ->
        message(values.bytes, values.required, values.payload)
      end)

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    if not valid_message?(fallback), do: raise(ArgumentError, "invalid fallback message")

    DiagnosticPattern.exact_message_schema(@maximum_message_bytes, @template)
  end
end
