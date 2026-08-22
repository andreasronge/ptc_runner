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

    # Mirrors an adapter whose backing application was started and then stopped:
    # its registry is gone, so it raises instead of returning an error tuple.
    if Application.get_env(:ptc_runner, :host_llm_test_raise, false) do
      raise ArgumentError, "unknown registry: FakeAdapter.Finch"
    end

    if Application.get_env(:ptc_runner, :host_llm_test_block, false) do
      receive do
        :host_llm_test_unblock -> :ok
      end
    end

    Application.get_env(
      :ptc_runner,
      :host_llm_test_result,
      {:ok, %{content: "ok", tokens: %{}}}
    )
  end

  @impl true
  def stream(_model, _request), do: {:error, :streaming_not_supported}

  # Defaults to nil so every other test keeps the unclassified transport path.
  @impl true
  def provider_application(model) do
    if owner = Application.get_env(:ptc_runner, :host_llm_provider_application_owner) do
      send(owner, {:host_llm_provider_application, model})
    end

    Application.get_env(:ptc_runner, :host_llm_test_provider_application)
  end

  @impl true
  def public_model(model) do
    if owner = Application.get_env(:ptc_runner, :host_llm_public_model_owner) do
      send(owner, {:host_llm_public_model, model})
    end

    if Application.get_env(:ptc_runner, :host_llm_test_public_model, false),
      do: {:ok, model},
      else: :private
  end

  @impl true
  def ensure_ready do
    owner = Application.fetch_env!(:ptc_runner, :host_llm_test_owner)
    send(owner, {:host_llm_ensure_ready, self()})

    case Application.get_env(:ptc_runner, :host_llm_test_ready_gate) do
      gate when is_reference(gate) ->
        receive do
          {^gate, :continue} -> :ok
        end

      _ungated ->
        :ok
    end

    _warm_words =
      :ptc_runner
      |> List.duplicate(Application.get_env(:ptc_runner, :host_llm_test_warm_words, 0))
      |> length()

    :ok
  end
end
