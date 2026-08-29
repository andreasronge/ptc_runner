defmodule PtcRunner.Kernel.LimitCapacityDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern
  alias PtcRunner.Kernel.LimitCatalog

  @prefix "event_payload_bytes effective limit "
  @required_middle " is below the required "
  @suffix " bytes for this application's resolved terminal usage; raise limits.event_payload_bytes, and its installed host ceiling if it is lower, or declare fewer capabilities or missions"
  @limit_pattern "(?:[1-9][0-9]{0,8}|1[0-9]{9}|2[0-4][0-9]{8}|25[0-8][0-9]{7}|259[0-1][0-9]{6}|2592000000)"
  @required_pattern "[1-9][0-9]{0,9}"
  @message_pattern ~r/^event_payload_bytes effective limit ([1-9][0-9]{0,9}) is below the required ([1-9][0-9]{0,9}) bytes for this application's resolved terminal usage; raise limits\.event_payload_bytes, and its installed host ceiling if it is lower, or declare fewer capabilities or missions$/
  @maximum_message_bytes byte_size(@prefix) + 10 + byte_size(@required_middle) + 10 +
                           byte_size(@suffix)

  @doc false
  @spec message(term(), term()) :: {:ok, binary()} | :error
  def message(payload, required) do
    with {:ok, payload_row} <- LimitCatalog.fetch(:event_payload_bytes),
         true <- LimitCatalog.valid_value?(payload_row, payload),
         true <- valid_required?(required),
         true <- payload < required do
      {:ok,
       @prefix <>
         Integer.to_string(payload) <>
         @required_middle <> Integer.to_string(required) <> @suffix}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    case Regex.run(@message_pattern, message) do
      [_all, payload, required] ->
        message(String.to_integer(payload), String.to_integer(required)) == {:ok, message}

      _no_match ->
        false
    end
  end

  def valid_message?(_message), do: false

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    if not valid_message?(fallback), do: raise(ArgumentError, "invalid fallback message")

    DiagnosticPattern.message_schema(
      @maximum_message_bytes,
      DiagnosticPattern.exact(
        DiagnosticPattern.escape(@prefix) <>
          @limit_pattern <>
          DiagnosticPattern.escape(@required_middle) <>
          @required_pattern <>
          DiagnosticPattern.escape(@suffix)
      )
    )
  end

  defp valid_required?(required)
       when is_integer(required) and required > 0 and required <= 9_999_999_999,
       do: true

  defp valid_required?(_required), do: false
end
