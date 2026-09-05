defmodule PtcRunner.Kernel.ModelOutputDiagnostic do
  @moduledoc false

  alias PtcRunner.LLM.OutputLimit

  @binding_lists (for mask <- 1..63 do
                    for {binding, index} <- Enum.with_index(OutputLimit.bindings()),
                        Bitwise.band(mask, Bitwise.bsl(1, index)) != 0,
                        do: binding
                  end)
  @prefix "model output for alias "
  @middle " was truncated without producing a usable run_ptc_lisp call; the request used "
  @generic "model output was truncated before producing a usable agent action"
  @token_value_pattern "(?:[1-9][0-9]{0,5}|1000000)"

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
         limit_phrase(limit.bindings, limit.value) <> ". " <> remedy(limit.bindings)}
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
      escape_pattern(@middle) <>
      limit_pattern(bindings) <>
      escape_pattern(". " <> remedy(bindings))
  end

  defp combined_schema_pattern do
    alternatives =
      Enum.map_join(@binding_lists, "|", fn bindings ->
        limit_pattern(bindings) <> escape_pattern(". " <> remedy(bindings))
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

  defp limit_phrase([:application_limit], value),
    do: "max_tokens #{value} from the application limit llm_request_output_tokens"

  defp limit_phrase([:installation_param], value),
    do: "max_tokens #{value} from the installation params.max_tokens"

  defp limit_phrase([:application_limit, :installation_param], value),
    do:
      "max_tokens #{value} from the application limit llm_request_output_tokens and installation params.max_tokens"

  defp limit_phrase(bindings, value),
    do: binding_phrase(bindings) <> " max_tokens " <> Integer.to_string(value)

  defp limit_pattern([:application_limit]),
    do: "max_tokens #{@token_value_pattern} from the application limit llm_request_output_tokens"

  defp limit_pattern([:installation_param]),
    do: "max_tokens #{@token_value_pattern} from the installation params\\.max_tokens"

  defp limit_pattern([:application_limit, :installation_param]),
    do:
      "max_tokens #{@token_value_pattern} from the application limit llm_request_output_tokens and installation params\\.max_tokens"

  defp limit_pattern(bindings),
    do: escape_pattern(binding_phrase(bindings) <> " max_tokens ") <> @token_value_pattern

  defp remedy(bindings) do
    actions = Enum.map(bindings, &remedy_action/1)
    join_actions(actions) <> ", or reduce the requested output"
  end

  defp remedy_action(:application_limit),
    do:
      "raise limits.llm_request_output_tokens in the application manifest and its installed host ceiling if lower"

  defp remedy_action(:installation_param),
    do: "raise params.max_tokens for that host installation if the model supports a larger output"

  defp remedy_action(:configured),
    do: "increase the direct adapter max_tokens option if the model supports a larger output"

  defp remedy_action(:adapter_default),
    do: "configure a larger max_tokens request if the model supports it"

  defp remedy_action(:model_output_limit),
    do: "select a model with a larger output limit"

  defp remedy_action(:remaining_context),
    do: "reduce the prompt or transcript or select a model with a larger context window"

  defp join_actions([action]), do: String.capitalize(action)
  defp join_actions([left, right]), do: String.capitalize(left) <> " and " <> right

  defp join_actions(actions) do
    {last, leading} = List.pop_at(actions, -1)
    String.capitalize(Enum.join(leading, ", ")) <> ", and " <> last
  end
end
