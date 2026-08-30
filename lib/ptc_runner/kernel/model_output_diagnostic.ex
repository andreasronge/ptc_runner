defmodule PtcRunner.Kernel.ModelOutputDiagnostic do
  @moduledoc false

  alias PtcRunner.LLM.OutputLimit

  @binding_lists (for mask <- 1..15 do
                    for {binding, index} <- Enum.with_index(OutputLimit.bindings()),
                        Bitwise.band(mask, Bitwise.bsl(1, index)) != 0,
                        do: binding
                  end)
  @prefix "model output for alias "
  @middle " was truncated without producing a usable run_ptc_lisp call; the request used "
  @generic "model output was truncated before producing a usable agent action"

  @spec message(map()) :: {:ok, binary()} | :error
  def message(%{
        limit: :max_tokens,
        limit_value: value,
        limit_bindings: bindings,
        alias: alias_name
      }) do
    with {:ok, limit} <-
           OutputLimit.normalize(%{name: :max_tokens, value: value, bindings: bindings}),
         true <- OutputLimit.valid_alias?(alias_name) do
      {:ok,
       @prefix <>
         alias_name <>
         @middle <>
         binding_phrase(limit.bindings) <>
         " max_tokens " <> Integer.to_string(limit.value) <> ". " <> remedy(limit.bindings)}
    else
      _invalid -> :error
    end
  end

  def message(%{alias: alias_name}) do
    if OutputLimit.valid_alias?(alias_name), do: {:ok, @generic}, else: :error
  end

  def message(_details), do: :error

  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    message == @generic or
      Enum.any?(@binding_lists, fn bindings ->
        Regex.match?(message_regex(bindings), message)
      end)
  end

  def valid_message?(_message), do: false

  @spec message_schema(binary()) :: map()
  def message_schema(fallback) do
    %{
      "oneOf" => [
        %{"const" => fallback},
        %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 1_024,
          "pattern" => combined_schema_pattern()
        }
      ]
    }
  end

  defp message_regex(bindings), do: Regex.compile!("\\A" <> pattern_body(bindings) <> "\\z")

  defp pattern_body(bindings) do
    escape_pattern(@prefix) <>
      "[a-z][a-z0-9._-]{0,127}" <>
      escape_pattern(@middle <> binding_phrase(bindings) <> " max_tokens ") <>
      "[1-9][0-9]*" <>
      escape_pattern(". " <> remedy(bindings))
  end

  defp combined_schema_pattern do
    alternatives =
      Enum.map_join(@binding_lists, "|", fn bindings ->
        escape_pattern(binding_phrase(bindings) <> " max_tokens ") <>
          "[1-9][0-9]*" <>
          escape_pattern(". " <> remedy(bindings))
      end)

    "^" <>
      escape_pattern(@prefix) <>
      "[a-z][a-z0-9._-]{0,127}" <>
      escape_pattern(@middle) <>
      "(?:" <> alternatives <> ")$"
  end

  defp escape_pattern(value) do
    value
    |> Regex.escape()
    |> String.replace("\\ ", " ")
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
  end

  defp binding_phrase(bindings), do: Enum.map_join(bindings, " and ", &Atom.to_string/1)

  defp remedy(bindings) do
    cond do
      :configured in bindings ->
        "Raise params.max_tokens for that host installation if the model supports a larger output, or reduce the requested output"

      :remaining_context in bindings ->
        "Reduce the prompt or transcript, select a model with a larger context window, or reduce the requested output"

      :model_output_limit in bindings ->
        "Select a model with a larger output limit or reduce the requested output"

      true ->
        "Set params.max_tokens higher if the model supports a larger output, or reduce the requested output"
    end
  end
end
