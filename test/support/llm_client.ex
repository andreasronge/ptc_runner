defmodule PtcRunner.TestSupport.LLMClient do
  @moduledoc """
  LLM client for E2E testing using ReqLLM.

  This module provides a simple interface for generating PTC programs
  from natural language task descriptions using LLM models. It supports
  both text mode (with manual cleanup) and structured output mode
  (with guaranteed valid JSON).

  ## Configuration

  Set environment variables or create a `.env` file in the project root:

      OPENROUTER_API_KEY=sk-or-...
      PTC_TEST_MODEL=haiku

  Use `LLMClient.aliases()` to see available model presets.

  ## Usage

      # Run e2e tests with default model
      mix test --include e2e

      # Run with specific model
      PTC_TEST_MODEL=haiku mix test --include e2e
  """

  alias PtcRunner.TestSupport.LLMSupport

  @doc """
  Generates a PTC program using text mode with the compact `to_prompt()` description.

  This tests whether LLMs can generate valid programs from a minimal,
  human-readable description (~300 tokens) without a full JSON schema.

  ## Arguments
    - task: Natural language description of what the program should do

  ## Returns
    The generated program as a JSON string.
  """
  @spec generate_program_text!(String.t()) :: String.t()
  def generate_program_text!(task) do
    LLMSupport.ensure_api_key!()

    prompt = """
    You are generating a PTC (Programmatic Tool Calling) program.

    #{PtcRunner.Schema.to_prompt()}

    Task: #{task}

    IMPORTANT: The input data is available via {"op": "load", "name": "input"}.

    Respond with ONLY valid JSON, no explanation or markdown formatting.
    """

    opts = [receive_timeout: LLMSupport.timeout(), req_http_options: LLMSupport.req_opts()]
    text = ReqLLM.generate_text!(LLMSupport.model(), prompt, opts)
    LLMSupport.clean_response(text, languages: ["json"])
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
  # Dialyzer struggles with ReqLLM's dynamic API - suppress for test support code
  @dialyzer {:nowarn_function, generate_program_structured!: 1}
  @spec generate_program_structured!(String.t()) :: String.t()
  def generate_program_structured!(task) do
    LLMSupport.ensure_api_key!()

    prompt = """
    Generate a PTC program for: #{task}

    Example - filter items where price > 10:
    {"program":{"op":"pipe","steps":[{"op":"load","name":"input"},{"op":"filter","where":{"op":"gt","field":"price","value":10}}]}}

    Example - sum all prices:
    {"program":{"op":"pipe","steps":[{"op":"load","name":"input"},{"op":"sum","field":"price"}]}}
    """

    llm_schema = PtcRunner.Schema.to_llm_schema()

    # Use structured output API - schema descriptions guide the LLM
    opts = [receive_timeout: LLMSupport.timeout(), req_http_options: LLMSupport.req_opts()]
    result = ReqLLM.generate_object!(LLMSupport.model(), prompt, llm_schema, opts)

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

  @doc """
  Returns the current model to use for LLM calls.

  Reads from PTC_TEST_MODEL environment variable, supporting both
  preset names (haiku, gemini, deepseek, kimi, gpt) and full model IDs.
  """
  defdelegate model, to: LLMSupport
end
