defmodule PtcRunner.Kernel.LimitCapacityDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern
  alias PtcRunner.Kernel.LimitCatalog

  @prefix "event_payload_bytes effective limit "
  @required_middle " is below the required "
  @suffix " bytes for this application's resolved terminal usage; raise limits.event_payload_bytes, and its installed host ceiling if it is lower, or declare fewer capabilities or missions"
  @limit_pattern "(?:[1-9][0-9]{0,8}|1[0-9]{9}|2[0-4][0-9]{8}|25[0-8][0-9]{7}|259[0-1][0-9]{6}|2592000000)"
  @required_pattern "[1-9][0-9]{0,9}"
  @maximum_required 9_999_999_999
  @maximum_message_bytes byte_size(@prefix) + 10 + byte_size(@required_middle) + 10 +
                           byte_size(@suffix)

  @template [
    {:literal, @prefix},
    {:slot, :payload, :integer, @limit_pattern},
    {:literal, @required_middle},
    {:slot, :required, :integer, @required_pattern},
    {:literal, @suffix}
  ]

  @doc """
  Builds the closed refusal naming the effective limit and what it must reach.

  Unlike the fixed structural relationship in `LimitConfigurationDiagnostic`,
  `required` scales with the resolved capability and mission inventory, so it
  cannot be recomputed from `payload` alone. It is validated as a bounded
  integer strictly above the limit that refused it.
  """
  @spec message(term(), term()) :: {:ok, binary()} | :error
  def message(payload, required) do
    with {:ok, payload_row} <- LimitCatalog.fetch(:event_payload_bytes),
         true <- LimitCatalog.valid_value?(payload_row, payload),
         true <- is_integer(required) and required in (payload + 1)..@maximum_required//1 do
      {:ok, DiagnosticPattern.render(@template, %{payload: payload, required: required})}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message),
    do:
      DiagnosticPattern.valid_template?(@template, message, fn values ->
        message(values.payload, values.required)
      end)

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    if not valid_message?(fallback), do: raise(ArgumentError, "invalid fallback message")

    DiagnosticPattern.exact_message_schema(@maximum_message_bytes, @template)
  end
end
