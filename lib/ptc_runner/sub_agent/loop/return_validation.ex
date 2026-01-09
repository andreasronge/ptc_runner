defmodule PtcRunner.SubAgent.Loop.ReturnValidation do
  @moduledoc """
  Return type validation for SubAgent execution.

  Validates return values against the agent's parsed signature and
  formats validation errors for LLM feedback.
  """

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Signature

  @doc """
  Validate return value against agent's parsed signature.

  Returns `:ok` or `{:error, [validation_error()]}`.
  """
  @spec validate(SubAgent.t(), term()) :: :ok | {:error, [Signature.validation_error()]}
  def validate(%{parsed_signature: nil}, _value), do: :ok
  def validate(%{parsed_signature: {:signature, _, :any}}, _value), do: :ok

  def validate(%{parsed_signature: parsed_sig}, value) do
    Signature.validate(parsed_sig, value)
  end

  @doc """
  Format validation error for LLM feedback.

  Builds an actionable error message that helps the LLM fix the return type.
  """
  @spec format_error_for_llm(SubAgent.t(), term(), [Signature.validation_error()]) :: String.t()
  def format_error_for_llm(agent, actual_value, errors) do
    expected_type = format_expected_type(agent)
    error_details = format_error_details(errors)
    actual_str = inspect(actual_value, limit: 10, pretty: false)
    truncated_actual = String.slice(actual_str, 0, 200)

    """
    Return type validation failed.
    Expected: #{expected_type}
    Received: #{truncated_actual}
    Errors:
    #{error_details}
    Please fix and call (return ...) with a correctly typed value.
    """
  end

  # Format expected type from signature
  defp format_expected_type(%{parsed_signature: nil}), do: ":any"

  defp format_expected_type(%{parsed_signature: {:signature, _, return_type}}) do
    Signature.Renderer.render_type(return_type)
  end

  # Format validation errors as a readable list
  defp format_error_details(errors) do
    Enum.map_join(errors, "\n", fn %{path: path, message: message} ->
      path_str = if path == [], do: "root", else: "[#{Enum.join(path, ".")}]"
      "- #{path_str}: #{message}"
    end)
  end
end
