defmodule PtcRunner.TestSupport.HostLLMAdapter do
  @moduledoc false

  @behaviour PtcRunner.LLM

  alias PtcRunner.LLM.Invocation
  alias PtcRunner.LLM.Requirements

  @impl true
  def prepare_model(model, requirements) do
    case Application.get_env(:ptc_runner, :host_llm_test_prepare_error) do
      nil ->
        case Requirements.canonical(requirements) do
          {:ok, canonical} ->
            status = Application.get_env(:ptc_runner, :host_llm_test_catalog_status, :unavailable)

            {:ok,
             %{
               selector: model,
               exact_options: canonical.exact_options,
               output_limit_bindings: canonical.output_limit_bindings
             }, status, canonical}

          :error ->
            {:error, :unsupported_model_option}
        end

      reason ->
        {:error, reason}
    end
  end

  @impl true
  def call(%{selector: model} = target, %Invocation{} = invocation) do
    send(Application.fetch_env!(:ptc_runner, :host_llm_test_owner), {
      :host_llm_request,
      model,
      Map.merge(invocation.request, %{
        probe_pid: self(),
        credential: invocation.credential,
        cache: invocation.cache,
        exact_options: Map.get(target, :exact_options, %{}),
        output_limit_bindings: Map.get(target, :output_limit_bindings, [:configured]),
        llm_request_deadline_ms: invocation.llm_request_deadline_ms
      })
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

  def call(_target, _invocation), do: {:error, :invalid_llm_invocation}

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
