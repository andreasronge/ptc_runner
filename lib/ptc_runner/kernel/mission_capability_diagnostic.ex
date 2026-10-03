defmodule PtcRunner.Kernel.MissionCapabilityDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.CapabilityRequirementDiagnostic
  alias PtcRunner.Kernel.DiagnosticPattern

  @mission_pattern "[a-z][a-z0-9._-]{0,127}"

  @spec message(term(), term()) :: {:ok, binary()} | :error
  def message(mission, names) when is_binary(mission) and is_list(names) do
    with true <- Regex.match?(Regex.compile!(DiagnosticPattern.exact(@mission_pattern)), mission),
         {:ok, _validated} <- CapabilityRequirementDiagnostic.message(names, "", "") do
      template = if length(names) == 1, do: hd(templates()), else: List.last(templates())

      rendered =
        DiagnosticPattern.render(template, %{mission: mission, names: Enum.join(names, ", ")})

      if byte_size(rendered) <= 1_100, do: {:ok, rendered}, else: :error
    else
      _invalid -> :error
    end
  end

  def message(_mission, _names), do: :error

  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) do
    Enum.any?(templates(), fn template ->
      DiagnosticPattern.valid_template?(template, message, fn values ->
        message(values.mission, String.split(values.names, ", "))
      end)
    end)
  end

  @spec message_schema(binary()) :: map()
  def message_schema(fallback) do
    %{
      "oneOf" => [
        %{"const" => fallback}
        | Enum.map(templates(), fn template ->
            DiagnosticPattern.exact_message_schema(1_100, template) |> Map.delete("minLength")
          end)
      ]
    }
  end

  defp templates do
    for tail <-
          CapabilityRequirementDiagnostic.templates(
            " has no providers; missing capability requirement: ",
            " has no providers; missing capability requirements: "
          ) do
      [
        {:literal, "mission \""},
        {:slot, :mission, :text, @mission_pattern},
        {:literal, "\""} | tail
      ]
    end
  end
end
