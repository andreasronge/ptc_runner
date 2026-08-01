defmodule PtcRunner.TestSupport.HostLLMAdapter do
  @moduledoc false

  @behaviour PtcRunner.LLM

  @impl true
  def call(model, request) do
    send(Application.fetch_env!(:ptc_runner, :host_llm_test_owner), {
      :host_llm_request,
      model,
      Map.put(request, :probe_pid, self())
    })

    Application.get_env(
      :ptc_runner,
      :host_llm_test_result,
      {:ok, %{content: "ok", tokens: %{}}}
    )
  end

  @impl true
  def stream(_model, _request), do: {:error, :streaming_not_supported}

  @impl true
  def ensure_ready do
    owner = Application.fetch_env!(:ptc_runner, :host_llm_test_owner)
    send(owner, {:host_llm_ensure_ready, self()})

    _warm_words =
      :ptc_runner
      |> List.duplicate(Application.get_env(:ptc_runner, :host_llm_test_warm_words, 0))
      |> length()

    :ok
  end
end
