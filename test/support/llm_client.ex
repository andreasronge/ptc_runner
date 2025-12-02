defmodule PtcRunner.TestSupport.LLMClient do
  @moduledoc """
  LLM client for E2E testing using ReqLLM and OpenRouter.

  This module provides a simple interface for generating PTC programs
  from natural language task descriptions using LLM models.
  """

  @model "openrouter:google/gemini-2.5-flash"
  @timeout 60_000

  @doc """
  Generates a PTC program from a natural language task description.

  ## Arguments
    - task: Natural language description of what the program should do
    - json_schema: The JSON Schema for the PTC DSL

  ## Returns
    The generated program as a JSON string.

  ## Raises
    Raises if the API key is not set or if the LLM call fails.
  """
  @spec generate_program!(String.t(), map()) :: String.t()
  def generate_program!(task, json_schema) do
    ensure_api_key!()

    prompt = """
    You are generating a PTC (Programmatic Tool Calling) program.

    JSON Schema:
    #{Jason.encode!(json_schema, pretty: true)}

    Task: #{task}

    IMPORTANT: The input data is available via {"op": "load", "name": "input"}.
    Operations like filter, map, select, sum, count, etc. require input data.
    Use a pipe operation to chain: first load the input, then apply transformations.

    Example for filtering: {"op": "pipe", "steps": [{"op": "load", "name": "input"}, {"op": "filter", "where": ...}]}

    Respond with ONLY valid JSON, no explanation or markdown formatting.
    """

    text = ReqLLM.generate_text!(@model, prompt, receive_timeout: @timeout)
    clean_response(text)
  end

  defp clean_response(text) do
    text
    |> String.trim()
    |> remove_markdown_fences()
  end

  defp remove_markdown_fences(text) do
    text
    |> String.replace(~r/^```json\s*/i, "")
    |> String.replace(~r/^```\s*/i, "")
    |> String.replace(~r/\s*```$/i, "")
    |> String.trim()
  end

  defp ensure_api_key! do
    unless System.get_env("OPENROUTER_API_KEY") do
      raise """
      OPENROUTER_API_KEY not set.

      For local development, create .env file with:
        OPENROUTER_API_KEY=sk-or-...

      For CI, ensure the secret is configured.
      """
    end
  end
end
