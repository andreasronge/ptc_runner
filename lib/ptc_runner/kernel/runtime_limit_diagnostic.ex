defmodule PtcRunner.Kernel.RuntimeLimitDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.LimitCatalog

  @prefix "subordinate_evaluations limit "
  @suffix " was exceeded; raise the manifest or host ceiling, or reduce total subordinate evaluations or agent turns"
  @limit_pattern "(?:[1-9][0-9]{0,8}|1[0-9]{9}|2[0-4][0-9]{8}|25[0-8][0-9]{7}|259[0-1][0-9]{6}|2592000000)"
  @maximum_digits 10
  @maximum_message_bytes byte_size(@prefix) + @maximum_digits + byte_size(@suffix)

  @doc false
  @spec subordinate_evaluations_message(term()) :: {:ok, binary()} | :error
  def subordinate_evaluations_message(limit) do
    with {:ok, row} <- LimitCatalog.fetch(:subordinate_evaluations),
         true <- LimitCatalog.valid_value?(row, limit) do
      {:ok, @prefix <> Integer.to_string(limit) <> @suffix}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    with true <- byte_size(message) <= @maximum_message_bytes,
         true <- String.starts_with?(message, @prefix),
         true <- String.ends_with?(message, @suffix),
         digits_bytes <- byte_size(message) - byte_size(@prefix) - byte_size(@suffix),
         true <- digits_bytes in 1..@maximum_digits,
         digits <-
           binary_part(
             message,
             byte_size(@prefix),
             digits_bytes
           ),
         {limit, ""} <- Integer.parse(digits),
         true <- Integer.to_string(limit) == digits,
         {:ok, expected} <- subordinate_evaluations_message(limit) do
      message == expected
    else
      _invalid -> false
    end
  end

  def valid_message?(_message), do: false

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    %{
      "oneOf" => [
        %{"const" => fallback},
        %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => @maximum_message_bytes,
          "pattern" =>
            "^subordinate_evaluations limit #{@limit_pattern} was exceeded; raise the manifest or host ceiling, or reduce total subordinate evaluations or agent turns$(?![\\s\\S])"
        }
      ]
    }
  end
end
