defmodule PtcRunner.TestSupport.LispLLMClient do
  @moduledoc """
  LLM client for PTC-Lisp E2E testing.

  This module provides a simple interface for generating PTC-Lisp programs
  from natural language task descriptions using LLM models.

  ## Configuration

  Set environment variables or create a `.env` file in the project root:

      OPENROUTER_API_KEY=sk-or-...
      PTC_TEST_MODEL=haiku

  Use `LLMClient.aliases()` to see available model presets.

  ## Usage

      # Run e2e tests with default model
      mix test test/ptc_runner/lisp/e2e_test.exs --include e2e

      # Run with specific model
      PTC_TEST_MODEL=haiku mix test test/ptc_runner/lisp/e2e_test.exs --include e2e
  """

  alias PtcRunner.Lisp.Prompts
  alias PtcRunner.TestSupport.LLM
  alias PtcRunner.TestSupport.LLMSupport

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
    LLMSupport.ensure_api_key!()

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

    model = LLMSupport.model()

    text =
      if LLMClient.requires_api_key?(model) do
        # Use ReqLLM for cloud providers
        opts = [receive_timeout: LLMSupport.timeout(), req_http_options: LLMSupport.req_opts()]
        ReqLLM.generate_text!(model, prompt, opts)
      else
        # Use LLMClient for local providers
        messages = [%{role: :user, content: prompt}]

        case LLM.generate_text(model, messages, receive_timeout: LLMSupport.timeout()) do
          {:ok, text} -> text
          {:error, reason} -> raise "LLM error: #{inspect(reason)}"
        end
      end

    LLMSupport.clean_response(text, languages: ["clojure", "lisp", "clj"])
  end

  @doc """
  Returns the current model to use for LLM calls.

  Reads from PTC_TEST_MODEL environment variable, supporting both
  preset names (haiku, gemini, etc.) and full model IDs.
  """
  defdelegate model, to: LLMSupport
end
