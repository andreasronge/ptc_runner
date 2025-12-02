defmodule PtcRunner.TestSupport.LLMClient do
  @moduledoc """
  LLM client for E2E testing using ReqLLM and OpenRouter.

  This module provides a simple interface for generating PTC programs
  from natural language task descriptions using LLM models. It supports
  both text mode (with manual cleanup) and structured output mode
  (with guaranteed valid JSON).
  """

  @model "openrouter:anthropic/claude-haiku-4.5"
  @timeout 60_000

  @doc """
  Generates a PTC program from a natural language task description using text mode.

  This function uses the LLM's text generation API and requires manual cleanup
  of markdown fences from the response.

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

  @doc """
  Generates a PTC program from a natural language task description using structured output mode.

  This function uses the LLM's structured output API, which guarantees valid JSON output.
  No manual cleanup is required.

  ## Arguments
    - task: Natural language description of what the program should do

  ## Returns
    The generated program as a JSON string.

  ## Raises
    Raises if the API key is not set or if the LLM call fails.
  """
  @spec generate_program_structured!(String.t()) :: String.t()
  def generate_program_structured!(task) do
    ensure_api_key!()

    prompt = """
    Generate a PTC program for: #{task}

    Example - filter items where price > 10:
    {"program":{"op":"pipe","steps":[{"op":"load","name":"input"},{"op":"filter","where":{"op":"gt","field":"price","value":10}}]}}

    Example - sum all prices:
    {"program":{"op":"pipe","steps":[{"op":"load","name":"input"},{"op":"sum","field":"price"}]}}
    """

    llm_schema = PtcRunner.Schema.to_llm_schema()

    # Use structured output API - schema descriptions guide the LLM
    result = ReqLLM.generate_object!(@model, prompt, llm_schema, receive_timeout: @timeout)

    # Wrap the result in the program envelope and return as JSON string
    case result do
      %{"program" => _} = wrapped ->
        Jason.encode!(wrapped)

      %{} = unwrapped ->
        # If for some reason the result doesn't have the program key,
        # wrap it now
        Jason.encode!(%{"program" => unwrapped})
    end
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
