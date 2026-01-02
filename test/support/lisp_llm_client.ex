defmodule PtcRunner.TestSupport.LispLLMClient do
  @moduledoc """
  LLM client for PTC-Lisp E2E testing using ReqLLM and OpenRouter.

  This module provides a simple interface for generating PTC-Lisp programs
  from natural language task descriptions using LLM models.

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
      mix test test/ptc_runner/lisp/e2e_test.exs --include e2e

      # Run with specific model
      PTC_TEST_MODEL=haiku mix test test/ptc_runner/lisp/e2e_test.exs --include e2e
  """

  alias PtcRunner.Lisp.Prompts
  alias PtcRunner.TestSupport.LLM

  @default_model "openrouter:google/gemini-2.5-flash"
  @timeout 60_000
  # Retry options for transient errors (502, 503, 504) via Req
  # :transient retries all HTTP methods (including POST), unlike :safe_transient
  @req_opts [retry: :transient, max_retries: 3]

  @model_presets %{
    # Cloud models (via OpenRouter)
    "haiku" => "openrouter:anthropic/claude-haiku-4.5",
    "devstral" => "openrouter:mistralai/devstral-2512:free",
    "gemini" => "openrouter:google/gemini-2.5-flash",
    "deepseek" => "openrouter:deepseek/deepseek-v3.2",
    "kimi" => "openrouter:moonshotai/kimi-k2",
    "gpt" => "openrouter:openai/gpt-5.1-codex-mini",
    # Local models (via Ollama)
    "deepseek-local" => "ollama:deepseek-coder:6.7b",
    "qwen-local" => "ollama:qwen2.5-coder:7b",
    "llama-local" => "ollama:llama3.2:3b"
  }

  @doc """
  Generates a PTC-Lisp program from a natural language task description.

  Uses the compact `PtcRunner.Lisp.Prompts.get(:single_shot)` reference to guide
  the LLM in generating valid PTC-Lisp code.

  ## Arguments
    - task: Natural language description of what the program should do

  ## Returns
    The generated program as a PTC-Lisp source string.
  """
  @spec generate_program!(String.t()) :: String.t()
  def generate_program!(task) do
    ensure_api_key!()

    prompt = """
    You are generating a PTC-Lisp program for data transformation.

    #{Prompts.get(:single_shot)}

    Available data (access via ctx/):
    - ctx/products - list of product maps with keys: name, price, category, in_stock
    - ctx/orders - list of order maps with keys: id, status, total, product_category
    - ctx/employees - list of employee maps with keys: name, department, salary

    Task: #{task}

    Return ONLY the PTC-Lisp expression, no explanation or markdown formatting.
    """

    text =
      if local_provider?(model()) do
        # Use TestSupport.LLM for local providers
        messages = [%{role: :user, content: prompt}]

        case LLM.generate_text(model(), messages, receive_timeout: @timeout) do
          {:ok, text} -> text
          {:error, reason} -> raise "LLM error: #{inspect(reason)}"
        end
      else
        # Use ReqLLM for cloud providers
        opts = [receive_timeout: @timeout, req_http_options: @req_opts]
        ReqLLM.generate_text!(model(), prompt, opts)
      end

    clean_response(text)
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

  defp clean_response(text) do
    text
    |> String.trim()
    |> remove_markdown_fences()
  end

  defp remove_markdown_fences(text) do
    text
    |> String.replace(~r/^```(?:clojure|lisp|clj)?\s*/i, "")
    |> String.replace(~r/^```\s*/i, "")
    |> String.replace(~r/\s*```$/i, "")
    |> String.trim()
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

    # Skip API key check for local providers
    unless local_provider?(model()) or System.get_env("OPENROUTER_API_KEY") do
      raise """
      OPENROUTER_API_KEY not set.

      For local development, create .env file with:
        OPENROUTER_API_KEY=sk-or-...
        PTC_TEST_MODEL=haiku  # optional, defaults to gemini

      Or use a local model (no API key required):
        PTC_TEST_MODEL=deepseek-local

      For CI, ensure the secret is configured.
      """
    end
  end

  defp local_provider?(model) do
    String.starts_with?(model, "ollama:") or
      String.starts_with?(model, "openai-compat:")
  end
end
