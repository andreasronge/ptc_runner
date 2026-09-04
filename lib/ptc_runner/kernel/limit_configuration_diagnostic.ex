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
  @message_pattern ~r/^normal_event_bytes effective limit ([1-9][0-9]{0,9}) is below the required ([1-9][0-9]{0,9}) bytes for event_payload_bytes ([1-9][0-9]{0,9}); raise limits\.normal_event_bytes, and its installed host ceiling if it is lower, or lower limits\.event_payload_bytes$/
  @maximum_message_bytes byte_size(@prefix) + 10 + byte_size(@required_middle) + 10 +
                           byte_size(@payload_middle) + 10 + byte_size(@suffix)

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
       @prefix <>
         Integer.to_string(bytes) <>
         @required_middle <>
         Integer.to_string(required) <>
         @payload_middle <> Integer.to_string(payload) <> @suffix}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    case Regex.run(@message_pattern, message) do
      [_all, bytes, required, payload] ->
        message(String.to_integer(bytes), String.to_integer(required), String.to_integer(payload)) ==
          {:ok, message}

      _no_match ->
        false
    end
  end

  def valid_message?(_message), do: false

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    if not valid_message?(fallback), do: raise(ArgumentError, "invalid fallback message")

    DiagnosticPattern.exact_message_schema(@maximum_message_bytes, [
      {:literal, @prefix},
      {:pattern, @limit_pattern},
      {:literal, @required_middle},
      {:pattern, @required_pattern},
      {:literal, @payload_middle},
      {:pattern, @limit_pattern},
      {:literal, @suffix}
    ])
  end
end
