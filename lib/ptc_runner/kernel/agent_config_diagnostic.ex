defmodule PtcRunner.Kernel.AgentConfigDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern

  # The shipped agent library rejects an out-of-range bounded option before it
  # spends a provider request, and its failure value carries the option and the
  # range it violated. Those are application-authored values, so the command
  # does not repeat them: it accepts the failure only when the option is one of
  # these four and the range it reports is the one this table holds. A prelude
  # that drifts therefore loses its dynamic message rather than publishing a
  # range the loop does not enforce.
  @options [
    {"max_turns", 1, 128},
    {"max_program_chars", 1, 1_000_000},
    {"max_observation_chars", 1, 65_536},
    {"max_transcript_chars", 1, 1_000_000}
  ]

  @doc false
  @spec options() :: [{binary(), pos_integer(), pos_integer()}]
  def options, do: @options

  @doc false
  @spec message(term(), term(), term()) :: {:ok, binary()} | :error
  for {option, minimum, maximum} <- @options do
    text =
      "#{option} is outside its accepted range; set #{option} in the agent " <>
        "configuration to an integer from #{minimum} to #{maximum}, " <>
        "or omit it for the documented default"

    def message(unquote(option), unquote(minimum), unquote(maximum)),
      do: {:ok, unquote(text)}
  end

  def message(_option, _minimum, _maximum), do: :error

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    Enum.any?(@options, fn {option, minimum, maximum} ->
      message(option, minimum, maximum) == {:ok, message}
    end)
  end

  def valid_message?(_message), do: false

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    %{"oneOf" => [%{"const" => fallback} | Enum.map(@options, &option_branch/1)]}
  end

  defp option_branch({option, minimum, maximum}) do
    {:ok, message} = message(option, minimum, maximum)

    %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => byte_size(message),
      "pattern" => DiagnosticPattern.exact(DiagnosticPattern.escape(message))
    }
  end
end
