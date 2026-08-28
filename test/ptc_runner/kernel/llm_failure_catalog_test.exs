defmodule PtcRunner.Kernel.LLMFailureCatalogTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.LLMFailureCatalog
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude

  test "ProviderError kinds and SafeMetadata consume names come from the catalog" do
    assert ProviderError.new(:denied, nil).kind == :denied

    assert Enum.all?(
             LLMFailureCatalog.provider_kinds(),
             &ProviderError.valid?(ProviderError.new(&1, nil))
           )

    for kebab <- LLMFailureCatalog.authenticated_kebabs() do
      assert LLMFailureCatalog.consume_kind(kebab) != nil
    end

    refute "unknown-model-alias" in LLMFailureCatalog.authenticated_kebabs()
    refute "invalid-model-alias" in LLMFailureCatalog.authenticated_kebabs()
    refute "model-alias-required" in LLMFailureCatalog.authenticated_kebabs()

    assert LLMFailureCatalog.consume_kind("provider-timeout") == :timeout
    assert LLMFailureCatalog.consume_kind("llm-request-timeout") == :timeout
    assert LLMFailureCatalog.consume_kind("timeout") == :timeout

    assert LLMFailureCatalog.consume_kind("reservation-bound-exceeded") ==
             :reservation_bound_exceeded

    refute ProviderError.valid?(%ProviderError{kind: :reservation_bound_exceeded})

    assert SafeMetadata.llm_provider_failure(%{
             kind: :llm_provider_error,
             reason: %{reason: :provider_timeout, retryable?: true}
           }) == %{llm_provider_failure: :timeout, llm_provider_retryable?: true}
  end

  test "generated agent.failure source matches the catalog projection" do
    assert File.read!("priv/preludes/kernel/agent.failure.clj") == LLMFailureCatalog.lisp_source()
  end

  test "classify admits every catalog spelling and stays out of the prompt inventory" do
    {:ok, components} = Library.components(["agent.failure"])
    {:ok, bundle} = Kernel.compile_bundle(components)

    assert Enum.map(Prelude.prompt_exports(bundle.prelude), & &1.ref) == []
    assert "agent.failure/classify" in Enum.map(bundle.prelude.exports, & &1.ref)

    classify = fn error ->
      {:ok, step} =
        Lisp.run_native("(agent.failure/classify error)",
          prelude: bundle.prelude,
          memory: %{"error" => error}
        )

      step.return
    end

    assert classify.(%{kind: :provider_error, reason: :not_found}) == true
    assert classify.(%{kind: :"provider-error", reason: :"rate-limited"}) == true
    assert classify.(%{kind: :protocol_error, reason: :invalid_model_alias}) == true
    assert classify.(%{kind: :"protocol-error", reason: :"unknown-model-alias"}) == true
    assert classify.(%{kind: :timeout, reason: :provider_timeout}) == true
    assert classify.(%{kind: :timeout, reason: :"llm-request-timeout"}) == true
    assert classify.(%{kind: :protocol_error, reason: :argument_exceeded}) == false
    assert classify.(:not_a_map) == false
  end
end
