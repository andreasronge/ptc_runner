defmodule PtcRunner.TestSupport.LLMSupport do
  @moduledoc """
  Shared utilities for LLM test support modules.

  Provides common functionality for:
  - Environment variable loading from .env files
  - Model name resolution
  - Response cleanup (removing markdown fences)
  - API key validation
  """

  alias PtcRunner.LLM.Registry
  alias PtcRunner.LLM.ReqLLMAdapter

  @default_model "openrouter:google/gemini-2.5-flash"
  @timeout 60_000
  @req_opts [retry: :transient, max_retries: 3]

  @doc """
  Get the default timeout for LLM requests.
  """
  def timeout, do: @timeout

  @doc """
  Get the default Req HTTP options.
  """
  def req_opts, do: @req_opts

  @doc """
  Get the current model from PTC_TEST_MODEL env var or return default.
  """
  @spec model() :: String.t()
  def model do
    case System.get_env("PTC_TEST_MODEL") do
      nil -> @default_model
      name -> resolve_model(name)
    end
  end

  @doc """
  Resolve a model name using the Registry.

  If the name is an alias, returns the full model ID.
  If resolution fails, returns the name as-is.
  """
  @spec resolve_model(String.t()) :: String.t()
  def resolve_model(name) do
    case Registry.resolve(name) do
      {:ok, model_id} -> model_id
      {:error, _} -> name
    end
  end

  @doc """
  Load environment variables from the nearest `.env` file.

  Delegates to `PtcRunner.Dotenv.load/0`.
  """
  @spec load_dotenv() :: :ok
  defdelegate load_dotenv, to: PtcRunner.Dotenv, as: :load

  @doc """
  Clean LLM response text by trimming and removing markdown fences.

  ## Options
    - `:languages` - List of language identifiers for code blocks (default: ["clojure", "lisp", "clj", "json"])
  """
  @spec clean_response(String.t(), keyword()) :: String.t()
  def clean_response(text, opts \\ []) do
    languages = Keyword.get(opts, :languages, ["clojure", "lisp", "clj", "json"])

    text
    |> String.trim()
    |> remove_markdown_fences(languages)
  end

  defp remove_markdown_fences(text, languages) do
    # Build pattern for specific languages
    lang_pattern = Enum.join(languages, "|")
    opening_pattern = ~r/^```(?:#{lang_pattern})?\s*/i

    text
    |> String.replace(opening_pattern, "")
    |> String.replace(~r/\s*```$/i, "")
    |> String.trim()
  end

  @doc """
  Ensure API key is available for the current model.

  Raises an error if the model requires an API key and none is set.
  """
  @spec ensure_api_key!() :: :ok
  def ensure_api_key! do
    load_dotenv()

    current_model = model()

    if ReqLLMAdapter.requires_api_key?(current_model) and
         is_nil(System.get_env("OPENROUTER_API_KEY")) do
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

    :ok
  end
end
