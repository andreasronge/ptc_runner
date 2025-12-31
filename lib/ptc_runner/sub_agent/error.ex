defmodule PtcRunner.SubAgentError do
  @moduledoc """
  Exception raised by `SubAgent.run!/2` and `SubAgent.then!/2` when execution fails.

  Contains the failed `Step` for inspection and debugging.

  ## Fields

  - `message`: Human-readable error description
  - `step`: The `Step` struct containing failure details

  ## Example

      try do
        SubAgent.run!(agent, llm: llm)
      rescue
        e in SubAgentError ->
          IO.inspect(e.step.fail.reason)
          IO.inspect(e.step.fail.message)
      end
  """

  defexception [:message, :step]

  @impl true
  def exception(%{step: step}) do
    msg = "SubAgent failed: #{step.fail.reason} - #{step.fail.message}"
    %__MODULE__{message: msg, step: step}
  end
end
