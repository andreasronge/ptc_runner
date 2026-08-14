defmodule PtcRunner.TestSupport.LLMSupport do
  @moduledoc """
  Shared utilities for LLM test support modules.

  Provides common functionality for:
  - Environment variable loading from .env files
  - Model name resolution
  - Response cleanup (removing markdown fences)
  - API key validation
  """

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderApplicationGate
  alias PtcRunner.LLM.ReqLLMAdapter

  @default_model "openrouter:deepseek/deepseek-v4-flash"
  @timeout 60_000
  @req_opts [retry: :transient, max_retries: 3]

  @doc """
  Admits the shipped LLM provider application for a test that builds providers
  directly.

  The core application starts no provider dependency, and a run normally admits
  one through `PtcRunner.Kernel.ProviderApplicationGate`. Tests that drive
  `ProviderRegistry` or `RunBuilder` without that gate must admit it here, and
  apply the same dependency dotenv and installed-default pool configuration as
  the command-owned gate, so no unchosen `.env` is read and live contention
  exercises the production geometry.

  That configuration is VM-global and persistent, so the admitting scope owns
  undoing it: the caller's `on_exit` restores the application environment and
  running set this admission found. Without that, a live module's command-owned
  pool geometry outlives it and every later test in the same VM inherits it —
  which is why this belongs here rather than in each caller.
  """
  @spec admit_provider_application!() :: :ok
  def admit_provider_application! do
    snapshot = snapshot_provider_applications()
    ExUnit.Callbacks.on_exit(fn -> restore_provider_applications(snapshot) end)

    stop_provider_applications()
    :ok = ProviderApplicationGate.configure_command_vm_req_llm(Limits.installed_defaults())
    {:ok, _started} = Application.ensure_all_started(:req_llm)
    :ok
  end

  @doc false
  def snapshot_provider_applications do
    %{
      running: Application.started_applications() |> MapSet.new(&elem(&1, 0)),
      req_llm_env: snapshot_application_env(:req_llm, req_llm_env_keys()),
      llm_db_env: snapshot_application_env(:llm_db, [:load_dotenv])
    }
  end

  @doc false
  def stop_provider_applications do
    running = Application.started_applications() |> MapSet.new(&elem(&1, 0))

    if MapSet.member?(running, :req_llm), do: Application.stop(:req_llm)
    if MapSet.member?(running, :llm_db), do: Application.stop(:llm_db)
    :ok
  end

  @doc false
  def restore_provider_applications(%{
        running: initially_running,
        req_llm_env: req_llm_env,
        llm_db_env: llm_db_env
      }) do
    :ok = stop_provider_applications()
    restore_application_env(:req_llm, req_llm_env)
    restore_application_env(:llm_db, llm_db_env)

    if MapSet.member?(initially_running, :llm_db),
      do: Application.ensure_all_started(:llm_db)

    if MapSet.member?(initially_running, :req_llm),
      do: Application.ensure_all_started(:req_llm)

    :ok
  end

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

  The value is a full provider-qualified identifier, such as
  `"openrouter:deepseek/deepseek-v4-flash"`.
  """
  @spec model() :: String.t()
  def model do
    System.get_env("PTC_TEST_MODEL") || @default_model
  end

  @doc """
  Load the root checkout's `.env` when it exists.
  """
  @spec load_dotenv() :: :ok
  def load_dotenv do
    if File.regular?(".env"), do: PtcRunner.Dotenv.load_file(".env"), else: :ok
  end

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

  defp req_llm_env_keys,
    do: [:finch, :load_dotenv, :stream_pool_count, :stream_pool_protocols, :stream_pool_size]

  defp snapshot_application_env(application, keys),
    do: Map.new(keys, &{&1, Application.fetch_env(application, &1)})

  defp restore_application_env(application, snapshot) do
    Enum.each(snapshot, fn
      {key, {:ok, value}} -> Application.put_env(application, key, value, persistent: true)
      {key, :error} -> Application.delete_env(application, key, persistent: true)
    end)
  end

  @doc """
  Ensure API key is available for the current model.

  Raises an error if the model requires an API key and none is set.
  """
  @spec ensure_api_key!(String.t() | nil) :: :ok
  def ensure_api_key!(model \\ nil) do
    load_dotenv()

    current_model = model || model()

    if ReqLLMAdapter.requires_api_key?(current_model) and
         is_nil(System.get_env("OPENROUTER_API_KEY")) do
      raise """
      OPENROUTER_API_KEY not set.

      For local development, create .env file with:
        OPENROUTER_API_KEY=sk-or-...
        PTC_TEST_MODEL=deepseek  # optional default

      Or use a local model (no API key required):
        PTC_TEST_MODEL=deepseek-local

      For CI, ensure the secret is configured.
      """
    end

    :ok
  end
end
