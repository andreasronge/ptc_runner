defmodule PtcRunner.TestSupport.HostLLMAdapter do
  @moduledoc false

  @behaviour PtcRunner.LLM

  @impl true
  def call(model, request) do
    send(Application.fetch_env!(:ptc_runner, :host_llm_test_owner), {
      :host_llm_request,
      model,
      request
    })

    {:ok, %{content: "ok", tokens: %{}}}
  end

  @impl true
  def stream(_model, _request), do: {:error, :streaming_not_supported}

  @impl true
  def ensure_ready, do: :ok
end
