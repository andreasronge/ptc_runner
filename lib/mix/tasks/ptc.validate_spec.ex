defmodule Mix.Tasks.Ptc.ValidateSpec do
  @moduledoc """
  Validates PTC-Lisp specification against implementation.

  Extracts examples from the specification and runs them through the PTC-Lisp
  interpreter to detect drift between specification and implementation.

  ## Usage

      mix ptc.validate_spec

  ## Output

  Displays:
  - Number of examples validated
  - Number of passed examples
  - Number of failed examples
  - Detailed failure information

  ## Exit Codes

  - 0: All examples passed
  - 1: Some examples failed
  - 2: Could not load or validate specification
  """

  use Mix.Task

  @shortdoc "Validate PTC-Lisp specification against implementation"

  alias PtcRunner.Lisp.SpecValidator

  @impl Mix.Task
  def run(_args) do
    case SpecValidator.validate_spec() do
      {:ok, results} ->
        display_results(results)

        if results.failed == 0 do
          :ok
        else
          System.halt(1)
        end

      {:error, reason} ->
        Mix.shell().error("Error: #{reason}")
        System.halt(2)
    end
  end

  defp display_results(results) do
    total = results.passed + results.failed
    percentage = if total > 0, do: round(results.passed / total * 100), else: 100

    Mix.shell().info("")
    Mix.shell().info("=== PTC-Lisp Specification Validation ===")
    Mix.shell().info("")
    Mix.shell().info("Total examples:  #{total}")
    Mix.shell().info("Passed:          #{results.passed}")
    Mix.shell().info("Failed:          #{results.failed}")
    Mix.shell().info("Success rate:    #{percentage}%")

    if results.failed > 0 do
      Mix.shell().info("")
      Mix.shell().info("=== Failures ===")
      Mix.shell().info("")

      Enum.each(Enum.reverse(results.failures), fn {code, expected, reason} ->
        Mix.shell().error("Code: #{code}")
        Mix.shell().error("Expected: #{inspect(expected)}")
        Mix.shell().error("Reason: #{reason}")
        Mix.shell().info("")
      end)
    end

    Mix.shell().info("")
  end
end
