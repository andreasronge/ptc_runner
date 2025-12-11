defmodule PtcRunner.TestSupport.LLMClient do
  @moduledoc """
  LLM client for E2E testing using ReqLLM and OpenRouter.

  This module provides a simple interface for generating PTC programs
  from natural language task descriptions using LLM models. It supports
  both text mode (with manual cleanup) and structured output mode
  (with guaranteed valid JSON).

  ## Configuration

  Set environment variables or create a `.env` file in the project root:

      OPENROUTER_API_KEY=sk-or-...
      PTC_TEST_MODEL=openrouter:anthropic/claude-haiku-4.5

  Available model presets (use short name or full model ID):
    - haiku: openrouter:anthropic/claude-haiku-4.5
    - devstral: openrouter:mistralai/devstral-2512:free
    - gemini: openrouter:google/gemini-2.5-flash
    - deepseek: openrouter:deepseek/deepseek-v3.2
    - kimi: openrouter:moonshotai/kimi-k2
    - gpt: openrouter:openai/gpt-5.1-codex-mini

  ## Usage

      # Run e2e tests with default model
      mix test test/ptc_runner/json/e2e_test.exs --include e2e

      # Run with specific model
      PTC_TEST_MODEL=haiku mix test test/ptc_runner/json/e2e_test.exs --include e2e
  """

  @default_model "openrouter:google/gemini-2.5-flash"
  @timeout 60_000

  @model_presets %{
    "haiku" => "openrouter:anthropic/claude-haiku-4.5",
    "devstral" => "openrouter:mistralai/devstral-2512:free",
    "gemini" => "openrouter:google/gemini-2.5-flash",
    "deepseek" => "openrouter:deepseek/deepseek-v3.2",
    "kimi" => "openrouter:moonshotai/kimi-k2",
    "gpt" => "openrouter:openai/gpt-5.1-codex-mini"
  }

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
    ensure_api_key!()

    prompt = """
    You are generating a PTC (Programmatic Tool Calling) program.

    #{PtcRunner.Schema.to_prompt()}

    Task: #{task}

    IMPORTANT: The input data is available via {"op": "load", "name": "input"}.

    Respond with ONLY valid JSON, no explanation or markdown formatting.
    """

    text = ReqLLM.generate_text!(model(), prompt, receive_timeout: @timeout)
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
    result = ReqLLM.generate_object!(model(), prompt, llm_schema, receive_timeout: @timeout)

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

  @doc """
  Returns the current model to use for LLM calls.

  Reads from PTC_TEST_MODEL environment variable, supporting both
  preset names (haiku, gemini, deepseek, kimi, gpt) and full model IDs.
  """
  def model do
    case System.get_env("PTC_TEST_MODEL") do
      nil -> @default_model
      name -> Map.get(@model_presets, name, name)
    end
  end

  defp load_dotenv do
    env_file =
      cond do
        File.exists?(".env") -> ".env"
        File.exists?("../.env") -> "../.env"
        true -> nil
      end

    if env_file do
      env_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.each(&parse_and_set_env_line/1)
    end
  end

  defp parse_and_set_env_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = String.trim(value)

        # Only set if not already set (env vars take precedence)
        unless System.get_env(key) do
          System.put_env(key, value)
        end

      _ ->
        :ok
    end
  end

  defp ensure_api_key! do
    load_dotenv()

    unless System.get_env("OPENROUTER_API_KEY") do
      raise """
      OPENROUTER_API_KEY not set.

      For local development, create .env file with:
        OPENROUTER_API_KEY=sk-or-...
        PTC_TEST_MODEL=haiku  # optional, defaults to gemini

      For CI, ensure the secret is configured.
      """
    end
  end
end
