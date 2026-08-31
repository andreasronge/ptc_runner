defmodule PtcRunner.Kernel.MissionCapabilityDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.CapabilityRequirementDiagnostic

  @max_name_bytes 128
  @mission_pattern "[a-z][a-z0-9._-]{0,127}"

  @spec message(term(), term()) :: {:ok, binary()} | :error
  def message(mission, names) when is_binary(mission) and is_list(names) do
    if valid_mission?(mission) do
      CapabilityRequirementDiagnostic.message(
        names,
        ~s(mission "#{mission}" has no providers; missing capability requirement: ),
        ~s(mission "#{mission}" has no providers; missing capability requirements: )
      )
    else
      :error
    end
  end

  def message(_mission, _names), do: :error

  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    case Regex.run(
           ~r/\Amission "([a-z][a-z0-9._-]{0,127})" has no providers; missing capability requirements?: (.+)\z/,
           message,
           capture: :all_but_first
         ) do
      [mission, names] -> message(mission, String.split(names, ", ")) == {:ok, message}
      _invalid -> false
    end
  end

  def valid_message?(_message), do: false

  @spec message_schema(binary()) :: map()
  def message_schema(fallback) do
    prefix = "mission \"#{@mission_pattern}\" has no providers; "

    CapabilityRequirementDiagnostic.message_schema(
      fallback,
      prefix <> "missing capability requirement: ",
      prefix <> "missing capability requirements: "
    )
  end

  defp valid_mission?(mission),
    do:
      byte_size(mission) <= @max_name_bytes and
        Regex.match?(~r/\A[a-z][a-z0-9._-]{0,127}\z/, mission)
end
