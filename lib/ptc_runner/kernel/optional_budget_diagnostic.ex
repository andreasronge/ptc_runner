defmodule PtcRunner.Kernel.OptionalBudgetDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern
  alias PtcRunner.Kernel.LimitCatalog

  @prerequisite_messages %{
    usage_tokens:
      "requires usage_guarantees.tokens: true on every live LLM installation; set it in the host document",
    usage_cost_currency:
      "requires usage_guarantees.cost_currency: \"USD\" on every live LLM installation; set it in the host document",
    reservation_tariff:
      "requires reservation_tariff on every live LLM installation; add it under each live LLM installation (see ptc docs host)"
  }

  @unavailable_middle " is unavailable because the host has not enabled it; enable "
  @unavailable_suffix " in the host document before declaring it in the manifest"

  @doc false
  @spec valid_prerequisite?(term(), term()) :: boolean()
  def valid_prerequisite?(limit, prerequisite) do
    case LimitCatalog.fetch(limit) do
      {:ok, %{scope: :optional_manifest_narrowable, prerequisites: prerequisites}} ->
        prerequisite in prerequisites

      _other ->
        false
    end
  end

  @doc false
  @spec prerequisite_message(term(), term()) :: {:ok, binary()} | :error
  def prerequisite_message(limit, prerequisite) do
    with {:ok, row} <- LimitCatalog.fetch(limit),
         true <- valid_prerequisite?(row.field, prerequisite),
         {:ok, suffix} <- Map.fetch(@prerequisite_messages, prerequisite) do
      {:ok, row.name <> " " <> suffix}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec valid_prerequisite_message?(term()) :: boolean()
  def valid_prerequisite_message?(message) when is_binary(message) do
    Enum.any?(LimitCatalog.rows(:optional_manifest_narrowable), fn row ->
      Enum.any?(row.prerequisites, fn prerequisite ->
        prerequisite_message(row.field, prerequisite) == {:ok, message}
      end)
    end)
  end

  def valid_prerequisite_message?(_message), do: false

  @doc false
  @spec prerequisite_message_schema(binary()) :: map()
  def prerequisite_message_schema(fallback) when is_binary(fallback) do
    messages =
      for row <- LimitCatalog.rows(:optional_manifest_narrowable),
          prerequisite <- row.prerequisites do
        {:ok, message} = prerequisite_message(row.field, prerequisite)
        message
      end

    %{"enum" => [fallback | messages] |> Enum.uniq() |> Enum.sort()}
  end

  @doc false
  @spec unavailable_message(term(), term()) :: {:ok, binary()} | :error
  def unavailable_message(limit, requested) do
    with {:ok, %{scope: :optional_manifest_narrowable} = row} <- LimitCatalog.fetch(limit),
         true <- is_integer(requested),
         true <- LimitCatalog.valid_value?(row, requested) do
      {:ok,
       row.name <>
         " " <>
         Integer.to_string(requested) <>
         @unavailable_middle <> row.name <> @unavailable_suffix}
    else
      _invalid -> :error
    end
  end

  @doc false
  @spec valid_unavailable_message?(term()) :: boolean()
  def valid_unavailable_message?(message) when is_binary(message) do
    Enum.any?(LimitCatalog.rows(:optional_manifest_narrowable), fn row ->
      prefix = row.name <> " "
      suffix = @unavailable_middle <> row.name <> @unavailable_suffix

      DiagnosticPattern.valid_exact_integer_message?(
        message,
        prefix,
        suffix,
        decimal_digits(row.maximum),
        fn requested ->
          unavailable_message(row.field, requested)
        end
      )
    end)
  end

  def valid_unavailable_message?(_message), do: false

  @doc false
  @spec unavailable_message_schema(binary()) :: map()
  def unavailable_message_schema(fallback) when is_binary(fallback) do
    branches =
      for row <- LimitCatalog.rows(:optional_manifest_narrowable) do
        prefix = row.name <> " "
        suffix = @unavailable_middle <> row.name <> @unavailable_suffix

        %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => byte_size(prefix) + decimal_digits(row.maximum) + byte_size(suffix),
          "pattern" =>
            DiagnosticPattern.exact(
              DiagnosticPattern.escape(prefix) <>
                positive_integer_pattern(row.maximum) <> DiagnosticPattern.escape(suffix)
            )
        }
      end

    %{"oneOf" => [%{"const" => fallback} | branches]}
  end

  # JSON Schema patterns compare text, not numbers. Build the exact decimal
  # language from 1 through the cataloged maximum so the published envelope
  # schema rejects an otherwise well-shaped value above the safe-integer bound.
  defp positive_integer_pattern(maximum) when is_integer(maximum) and maximum > 0 do
    digits = Integer.digits(maximum)
    maximum_text = Integer.to_string(maximum)
    digit_count = length(digits)

    shorter =
      if digit_count == 1,
        do: [],
        else: ["[1-9][0-9]{0,#{digit_count - 2}}"]

    bounded =
      digits
      |> Enum.with_index()
      |> Enum.flat_map(fn {digit, index} ->
        lower = if index == 0, do: 1, else: 0
        upper = digit - 1

        if upper < lower do
          []
        else
          prefix = digits |> Enum.take(index) |> Enum.join()
          choice = if lower == upper, do: Integer.to_string(lower), else: "[#{lower}-#{upper}]"
          remaining = digit_count - index - 1
          suffix = if remaining == 0, do: "", else: "[0-9]{#{remaining}}"
          [prefix <> choice <> suffix]
        end
      end)

    "(?:" <> Enum.join(shorter ++ bounded ++ [maximum_text], "|") <> ")"
  end

  defp decimal_digits(value), do: value |> Integer.to_string() |> byte_size()
end
