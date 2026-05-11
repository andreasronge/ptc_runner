defmodule PtcRunnerMcp.Agentic.Planner do
  @moduledoc false

  alias PtcRunner.LLM
  alias PtcRunner.LLM.Registry
  alias PtcRunnerMcp.Credentials.Redactor

  @spec call(String.t(), String.t(), keyword()) ::
          {:ok, String.t(), map()} | {:error, :config | :planner, String.t(), map()}
  def call(model, prompt, opts) when is_binary(model) and is_binary(prompt) and is_list(opts) do
    with {:ok, resolved} <- resolve_model(model),
         :ok <- check_api_key(resolved) do
      request = %{
        system: "You generate only PTC-Lisp programs.",
        messages: [%{role: :user, content: prompt}],
        receive_timeout: Keyword.fetch!(opts, :timeout_ms),
        max_tokens: Keyword.fetch!(opts, :max_output_tokens)
      }

      started = System.monotonic_time(:millisecond)

      case LLM.call(resolved, request) do
        {:ok, %{content: content} = response} when is_binary(content) ->
          duration = System.monotonic_time(:millisecond) - started

          {:ok, content,
           %{
             "model" => resolved,
             "duration_ms" => duration,
             "prompt_bytes" => byte_size(prompt),
             "output_bytes" => byte_size(content),
             "tokens" => Map.get(response, :tokens, %{})
           }}

        {:ok, other} ->
          {:error, :planner, "planner returned no text content: #{inspect(other, limit: 20)}",
           %{"model" => resolved, "prompt_bytes" => byte_size(prompt)}}

        {:error, reason} ->
          {:error, :planner, inspect(reason, limit: 20),
           %{"model" => resolved, "prompt_bytes" => byte_size(prompt)}}
      end
    end
  end

  defp resolve_model(model) do
    {:ok, Registry.resolve!(model)}
  rescue
    e in ArgumentError -> {:error, :config, Exception.message(e), %{"model" => model}}
  end

  defp check_api_key("openrouter:" <> _model) do
    case System.get_env("OPENROUTER_API_KEY") do
      nil ->
        {:error, :config, "OPENROUTER_API_KEY is required for OpenRouter planner models", %{}}

      "" ->
        {:error, :config, "OPENROUTER_API_KEY is required for OpenRouter planner models", %{}}

      _ ->
        :ok
    end
  end

  defp check_api_key(_model), do: :ok

  @spec sanitize_prompt(String.t()) :: String.t()
  def sanitize_prompt(prompt) do
    Redactor.scrub(prompt)
  rescue
    _ -> prompt
  end
end
