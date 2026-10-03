defmodule PtcRunner.Kernel.ModelContractDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern

  @prefix "llm_cost_microusd requires supported USD reservation pricing for "
  @suffix "; remove limits.llm_cost_microusd, or select a model with supported USD reservation pricing"
  @max_model_bytes 256
  @max_encoded_model_bytes @max_model_bytes * 2 + 2
  @max_message_bytes byte_size(@prefix) + @max_encoded_model_bytes + byte_size(@suffix)
  @json_string ~S'"(?:[\x20-\x21\x23-\x5b\x5d-\x7e]|\\["\\]){1,256}"'

  @selected_model "the selected model"
  @template [
    {:literal, @prefix},
    {:slot, :model, :text,
     "(?:" <> DiagnosticPattern.escape(@selected_model) <> "|" <> @json_string <> ")"},
    {:literal, @suffix}
  ]

  @spec cost_reservation_pricing_message(binary() | nil) :: binary()
  def cost_reservation_pricing_message(nil),
    do: DiagnosticPattern.render(@template, %{model: @selected_model})

  def cost_reservation_pricing_message(model) when is_binary(model) do
    if publishable_model?(model),
      do: DiagnosticPattern.render(@template, %{model: Jason.encode!(model)}),
      else: cost_reservation_pricing_message(nil)
  end

  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    message == cost_reservation_pricing_message(nil) or valid_public_model_message?(message)
  end

  def valid_message?(_message), do: false

  @doc false
  @spec pricing_model(term()) :: {:ok, binary() | nil} | :error
  def pricing_model(message) when is_binary(message) do
    cond do
      message == cost_reservation_pricing_message(nil) ->
        {:ok, nil}

      valid_public_model_message?(message) ->
        message
        |> String.trim_leading(@prefix)
        |> String.trim_trailing(@suffix)
        |> Jason.decode()

      true ->
        :error
    end
  end

  def pricing_model(_message), do: :error

  @doc false
  @spec model_uncataloged_message(binary() | nil) :: binary()
  def model_uncataloged_message(public_model) do
    identity = if publishable_model?(public_model), do: " #{inspect(public_model)}", else: ""

    "model_uncataloged: configured model#{identity} is not an exact catalog entry; " <>
      "pricing, limits, token estimation, and capability detection may be incomplete"
  end

  @doc false
  @spec warning_line(term()) :: binary()
  def warning_line(message) do
    case pricing_model(message) do
      {:ok, public_model} ->
        "warning: " <> model_uncataloged_message(public_model) <> "\n"

      :error ->
        ""
    end
  end

  @spec message_schema(binary()) :: map()
  def message_schema(fallback) do
    %{
      "oneOf" => [
        %{"const" => fallback},
        DiagnosticPattern.exact_message_schema(@max_message_bytes, @template)
      ]
    }
  end

  defp valid_public_model_message?(message) do
    with {:ok, %{model: encoded}} <- DiagnosticPattern.parse(@template, message),
         {:ok, model} when is_binary(model) <- Jason.decode(encoded) do
      publishable_model?(model) and message == cost_reservation_pricing_message(model)
    else
      _invalid -> false
    end
  end

  defp publishable_model?(model) when is_binary(model) do
    byte_size(model) in 1..@max_model_bytes and
      :binary.bin_to_list(model) |> Enum.all?(&(&1 in 0x20..0x7E))
  end

  defp publishable_model?(_model), do: false
end
