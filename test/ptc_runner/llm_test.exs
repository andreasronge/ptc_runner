defmodule PtcRunner.LLMTest do
  # async: false because tests mutate `Application.put_env(:ptc_runner,
  # :llm_adapter, ...)` which is global. Under async: true a concurrent
  # test can clobber the adapter mid-run.
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ModelContractDiagnostic
  alias PtcRunner.LLM.Invocation
  alias PtcRunner.LLM.PreparedModel
  alias PtcRunner.LLM.Requirements
  alias PtcRunner.TestSupport.LLMSupport

  defmodule StubAdapter do
    defmacro __using__(opts) do
      catalog_status = Keyword.get(opts, :catalog_status, :unavailable)

      quote do
        @behaviour PtcRunner.LLM

        @impl true
        def prepare_model(model, requirements) do
          {:ok, %{selector: model, exact_options: requirements.exact_options},
           unquote(catalog_status), requirements}
        end

        @impl true
        def call(_target, _invocation), do: {:ok, %{content: "", tokens: %{}}}

        defoverridable prepare_model: 2, call: 2
      end
    end
  end

  defmodule MockAdapter do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def call(_target, %Invocation{request: %{schema: _schema}}) do
      {:ok, %{object: %{answer: "structured"}, tokens: %{input: 5, output: 3}}}
    end

    def call(_target, %Invocation{request: req}) do
      {:ok, %{content: "mock response for: #{req.system}", tokens: %{input: 10, output: 5}}}
    end
  end

  defmodule ReadyProbe do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def ensure_ready do
      Process.put({__MODULE__, :called}, true)
      :ok
    end
  end

  defmodule PublicModelAdapter do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def public_model(model), do: {:ok, model}
  end

  defmodule PreparingAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def prepare_model(model, requirements) do
      send(self(), {:prepared_model, model, requirements.exact_options})
      {:ok, {:prepared, model, requirements.exact_options}, :unavailable, requirements}
    end

    @impl true
    def call({:prepared, model, exact_options}, %Invocation{} = invocation) do
      send(self(), {:called_prepared_model, model, invocation.request, exact_options, invocation})
      {:ok, %{content: "prepared", tokens: %{}}}
    end
  end

  defmodule FailingPreparationAdapter do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def prepare_model(_model, _requirements), do: {:error, :model_unavailable}

    @impl true
    def call(_target, _invocation), do: raise("a failed preparation must not reach call/2")
  end

  defmodule UnsupportedOptionAdapter do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def prepare_model(_model, _requirements), do: {:error, :unsupported_model_option}

    @impl true
    def call(_target, _invocation), do: raise("an unsupported contract must not reach call/2")
  end

  defmodule RawPricingPayloadAdapter do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def prepare_model(_model, _requirements),
      do: {:error, {:uncataloged_cost_reservation_pricing_unavailable, "PRIVATE ENDPOINT"}}

    @impl true
    def call(_target, _invocation), do: raise("a forged pricing cause must not reach call/2")
  end

  defmodule PricingUnavailableAdapter do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def prepare_model(_model, _requirements),
      do: {:error, :uncataloged_cost_reservation_pricing_unavailable}
  end

  defmodule GenericPricingUnavailableAdapter do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def prepare_model(_model, _requirements), do: {:error, :cost_reservation_pricing_unavailable}
  end

  defmodule MismatchingAttestationAdapter do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def prepare_model(model, requirements) do
      attestation = put_in(requirements, [:exact_options, :max_tokens], 1)
      {:ok, %{selector: model}, :unavailable, attestation}
    end

    @impl true
    def call(_target, _invocation), do: raise("a mismatched attestation must not reach call/2")
  end

  defmodule UncatalogedPublicAdapter do
    use PtcRunner.LLMTest.StubAdapter, catalog_status: :uncataloged

    @impl true
    def public_model(model), do: {:ok, model}
  end

  defmodule UncatalogedPrivateAdapter do
    use PtcRunner.LLMTest.StubAdapter, catalog_status: :uncataloged
  end

  defmodule MismatchingPublicModelAdapter do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def public_model(_model), do: {:ok, "provider:different"}
  end

  defmodule RaisingPublicModelAdapter do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def public_model(_model), do: raise("private adapter detail")
  end

  defmodule ReservationAdapter do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def reservation_bound(_target, request, tariff) do
      send(self(), {:reservation_bound, request, tariff})

      %{
        total_tokens: 17,
        cost: %{currency: "USD", microunits: 23, tariff_id: tariff.id}
      }
    end
  end

  defmodule RaisingReservationAdapter do
    use PtcRunner.LLMTest.StubAdapter

    @impl true
    def reservation_bound(_target, _request, _tariff), do: raise("private tariff detail")
  end

  setup do
    prev = Application.get_env(:ptc_runner, :llm_adapter)
    Application.put_env(:ptc_runner, :llm_adapter, MockAdapter)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ptc_runner, :llm_adapter, prev),
        else: Application.delete_env(:ptc_runner, :llm_adapter)
    end)

    :ok
  end

  defp requirements(extra \\ %{}) do
    LLMSupport.interim_requirements(Map.merge(%{max_tokens: 4_096}, extra))
  end

  defp prepare!(model, extra \\ %{}, adapter \\ nil) do
    args =
      if adapter,
        do: [model, requirements(extra), adapter],
        else: [model, requirements(extra)]

    assert {:ok, prepared} = apply(PtcRunner.LLM, :prepare, args)
    prepared
  end

  describe "prepare/2 adapter warmup" do
    test "invokes the adapter's ensure_ready/0 at prepare time" do
      Process.delete({ReadyProbe, :called})

      assert {:ok, _prepared} =
               PtcRunner.LLM.prepare("ollama:test-model", requirements(), ReadyProbe)

      assert Process.get({ReadyProbe, :called}) == true
    end

    test "is a no-op for adapters that do not implement ensure_ready/0" do
      assert {:ok, prepared} = PtcRunner.LLM.prepare("ollama:test-model", requirements())
      assert PreparedModel.valid?(prepared)
    end
  end

  describe "prepare/2" do
    test "seals equal requirements and attestation onto the prepared target" do
      requested = requirements(%{temperature: 0.25, seed: 7})

      assert {:ok, prepared} =
               PtcRunner.LLM.prepare("provider:model", requested, PreparingAdapter)

      assert_receive {:prepared_model, "provider:model",
                      %{max_tokens: 4_096, temperature: 0.25, seed: 7}}

      assert prepared.requirements == requested
      assert prepared.attestation == requested
      assert prepared.target == {:prepared, "provider:model", requested.exact_options}
      assert PreparedModel.valid?(prepared)
    end

    test "rejects a mismatched adapter attestation as an unsupported contract" do
      assert {:error, :unsupported_model_option} =
               PtcRunner.LLM.prepare(
                 "provider:model",
                 requirements(),
                 MismatchingAttestationAdapter
               )
    end

    test "returns adapter unsupported-option failures before constructing a requester" do
      assert {:error, :unsupported_model_option} =
               PtcRunner.LLM.prepare("provider:model", requirements(), UnsupportedOptionAdapter)
    end

    test "rejects an adapter-supplied pricing payload instead of publishing it" do
      assert {:error, :invalid_model_preparation} =
               PtcRunner.LLM.prepare("provider:model", requirements(), RawPricingPayloadAdapter)
    end

    test "rejects a pricing sentinel when no cost reservation was requested" do
      assert {:error, :invalid_model_preparation} =
               PtcRunner.LLM.prepare("provider:model", requirements(), PricingUnavailableAdapter)
    end

    test "does not classify a generic adapter pricing miss as uncataloged" do
      tariff = %{currency: "USD", id: "test-v1"}
      requested = put_in(requirements(), [:reservation, :cost_tariff], tariff)

      assert {:error, :cost_reservation_pricing_unavailable} =
               PtcRunner.LLM.prepare(
                 "provider:model",
                 requested,
                 GenericPricingUnavailableAdapter
               )
    end

    test "returns preparation failures before constructing a requester" do
      assert {:error, :model_unavailable} =
               PtcRunner.LLM.prepare("provider:model", requirements(), FailingPreparationAdapter)
    end

    test "rejects a copied or mutated prepared model" do
      prepared = prepare!("provider:model", %{}, PreparingAdapter)
      copied = Map.put(prepared, :target, :forged)
      refute PreparedModel.valid?(copied)

      assert {:error, :invalid_prepared_model} =
               PtcRunner.LLM.callback(copied, LLMSupport.llm_binding())
    end
  end

  describe "reservation_bound/3" do
    test "delegates only with the tariff sealed into the prepared model" do
      tariff = %{currency: "USD", id: "fixture-v1"}

      requested = %{
        requirements()
        | usage_guarantees: %{tokens: true, cost_currency: "USD"},
          reservation: %{total_tokens?: true, cost_tariff: tariff}
      }

      assert {:ok, prepared} =
               PtcRunner.LLM.prepare("provider:model", requested, ReservationAdapter)

      request = %{"messages" => []}

      assert {:ok,
              %{
                total_tokens: 17,
                cost: %{currency: "USD", microunits: 23, tariff_id: "fixture-v1"}
              }} = PtcRunner.LLM.reservation_bound(prepared, request, tariff)

      assert_receive {:reservation_bound, ^request, ^tariff}

      assert {:error, :reservation_attestation_unavailable} =
               PtcRunner.LLM.reservation_bound(
                 prepared,
                 request,
                 %{currency: "USD", id: "other-v1"}
               )

      refute_receive {:reservation_bound, _, _}
    end

    test "fails closed when the adapter omits or raises in reservation attestation" do
      tariff = %{currency: "USD", id: "fixture-v1"}

      requested = %{
        requirements()
        | usage_guarantees: %{tokens: true, cost_currency: "USD"},
          reservation: %{total_tokens?: true, cost_tariff: tariff}
      }

      assert {:ok, missing} =
               PtcRunner.LLM.prepare("provider:model", requested, PreparingAdapter)

      assert {:ok, raising} =
               PtcRunner.LLM.prepare("provider:model", requested, RaisingReservationAdapter)

      assert {:error, :reservation_attestation_unavailable} =
               PtcRunner.LLM.reservation_bound(missing, %{}, tariff)

      assert {:error, :reservation_attestation_unavailable} =
               PtcRunner.LLM.reservation_bound(raising, %{}, tariff)
    end
  end

  describe "callback/2" do
    test "prepares a model once when the requester is constructed" do
      prepared = prepare!("provider:model", %{temperature: 0.25}, PreparingAdapter)
      assert_receive {:prepared_model, "provider:model", %{max_tokens: 4_096, temperature: 0.25}}
      refute_receive {:prepared_model, _model, _options}

      {:ok, callback} = PtcRunner.LLM.callback(prepared, LLMSupport.llm_binding())
      assert is_function(callback, 2)

      assert {:ok, %{content: "prepared"}} =
               callback.(%{system: "test", messages: []}, LLMSupport.llm_context())

      assert_receive {:called_prepared_model, "provider:model", %{system: "test", messages: []},
                      %{max_tokens: 4_096, temperature: 0.25},
                      %Invocation{cache: false, credential: nil, llm_request_deadline_ms: nil}}

      assert {:ok, %{content: "prepared"}} =
               callback.(%{system: "again", messages: []}, LLMSupport.llm_context())

      refute_receive {:prepared_model, _model, _options}

      assert_receive {:called_prepared_model, "provider:model", %{system: "again"}, _options,
                      _invocation}
    end

    test "refuses a string model at the callback boundary" do
      assert {:error, :invalid_prepared_model} =
               PtcRunner.LLM.callback("ollama:test-model", LLMSupport.llm_binding())
    end

    test "refuses an open binding map" do
      prepared = prepare!("ollama:test-model")

      assert {:error, :invalid_llm_binding} =
               PtcRunner.LLM.callback(prepared, %{credential: nil, cache: false, api_key: "x"})
    end

    test "emits an uncataloged warning once without publishing unattested selectors" do
      public_warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          prepared = prepare!("provider:public", %{}, UncatalogedPublicAdapter)
          assert {:ok, _requester} = PtcRunner.LLM.callback(prepared, LLMSupport.llm_binding())
        end)

      private_warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          prepared = prepare!("provider:private", %{}, UncatalogedPrivateAdapter)
          assert {:ok, _requester} = PtcRunner.LLM.callback(prepared, LLMSupport.llm_binding())
        end)

      assert public_warning =~ "model_uncataloged"
      assert public_warning =~ "provider:public"

      assert public_warning ==
               captured_warning(
                 ModelContractDiagnostic.model_uncataloged_message("provider:public")
               )

      assert private_warning =~ "model_uncataloged"
      refute private_warning =~ "provider:private"
    end

    test "withholds selectors outside the refusal warning's printable ASCII grammar" do
      for selector <- ["provider:public\nwarning: forged", "provider:café"] do
        warning =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            prepared = prepare!(selector, %{}, UncatalogedPublicAdapter)
            assert {:ok, _requester} = PtcRunner.LLM.callback(prepared, LLMSupport.llm_binding())
          end)

        assert warning == captured_warning(ModelContractDiagnostic.model_uncataloged_message(nil))

        refute warning =~ selector
      end
    end

    test "returns a function that calls the adapter" do
      prepared = prepare!("ollama:test-model")
      {:ok, callback} = PtcRunner.LLM.callback(prepared, LLMSupport.llm_binding())
      assert is_function(callback, 2)

      {:ok, resp} = callback.(%{system: "test", messages: []}, LLMSupport.llm_context())
      assert resp.content == "mock response for: test"
      assert resp.tokens.input == 10
    end

    test "does not merge request-authored stream functions into adapter invocation" do
      prepared = prepare!("ollama:test-model")
      {:ok, callback} = PtcRunner.LLM.callback(prepared, LLMSupport.llm_binding())

      {:ok, resp} =
        callback.(
          %{system: "test", messages: [], stream: fn _chunk -> :ok end},
          LLMSupport.llm_context()
        )

      assert resp.content == "mock response for: test"
    end
  end

  describe "Requirements" do
    test "live authorization is the minimum of the effective limit and installed max_tokens" do
      guarantees = %{tokens: true, cost_currency: "USD"}
      reservation = %{total_tokens?: false, cost_tariff: nil}

      assert {:ok, authorized} =
               Requirements.live(
                 %{max_tokens: 2_048, temperature: 0.15},
                 4_096,
                 :unsupported,
                 guarantees,
                 reservation
               )

      assert authorized.exact_options == %{max_tokens: 2_048, temperature: 0.15}
      assert authorized.output_limit_bindings == [:installation_param]
      assert authorized.structured_output_mode == :unsupported
      assert authorized.usage_guarantees == %{tokens: true, cost_currency: "USD"}

      assert {:ok, limited} =
               Requirements.live(
                 %{max_tokens: 8_192},
                 4_096,
                 :unsupported,
                 guarantees,
                 reservation
               )

      assert limited.exact_options == %{max_tokens: 4_096}
      assert limited.output_limit_bindings == [:application_limit]

      assert {:ok, omitted} = Requirements.live(%{}, 1_024, :unsupported, guarantees, reservation)
      assert omitted.exact_options == %{max_tokens: 1_024}
      assert omitted.output_limit_bindings == [:application_limit]

      assert {:ok, tied} =
               Requirements.live(
                 %{max_tokens: 4_096},
                 4_096,
                 :unsupported,
                 guarantees,
                 reservation
               )

      assert tied.output_limit_bindings == [:application_limit, :installation_param]

      for impossible <- [
            [:application_limit, :configured],
            [:installation_param, :configured],
            [:application_limit, :installation_param, :configured]
          ] do
        assert :error = Requirements.canonical(%{tied | output_limit_bindings: impossible})
      end

      for invalid <- [0, -1, "4096", nil] do
        assert :error =
                 Requirements.live(
                   %{max_tokens: invalid},
                   4_096,
                   :unsupported,
                   guarantees,
                   reservation
                 )
      end

      assert {:ok, structured} =
               Requirements.live(%{max_tokens: 256}, 4_096, :json_schema, guarantees, reservation)

      assert structured.structured_output_mode == :json_schema
      assert structured.exact_options == %{max_tokens: 256}

      assert {:ok, probe} = Requirements.probe(%{max_tokens: 99}, guarantees)
      assert probe.structured_output_mode == :unsupported
      assert probe.usage_guarantees == guarantees
    end

    test "probe authorization forces max_tokens 1 and keeps other installation controls" do
      params = %{
        max_tokens: 99,
        seed: 7,
        top_p: 0.9,
        presence_penalty: -0.5,
        frequency_penalty: 0.75,
        reasoning_effort: :medium
      }

      assert {:ok, probe} =
               Requirements.probe(params, %{tokens: false, cost_currency: nil})

      assert probe.exact_options == Map.put(params, :max_tokens, 1)
    end

    test "canonicalizes the complete closed inference-control set" do
      exact = %{
        max_tokens: 512,
        temperature: 1,
        seed: 0,
        top_p: 1,
        presence_penalty: -2,
        frequency_penalty: 2,
        reasoning_effort: :high
      }

      assert {:ok, canonical} = exact |> Requirements.interim() |> Requirements.canonical()

      assert canonical.exact_options == %{
               exact
               | temperature: 1.0,
                 top_p: 1.0,
                 presence_penalty: -2.0,
                 frequency_penalty: 2.0
             }

      for invalid <- [
            %{exact | top_p: 0},
            %{exact | top_p: 1.01},
            %{exact | presence_penalty: -2.01},
            %{exact | frequency_penalty: 2.01},
            %{exact | reasoning_effort: :xhigh},
            Map.put(exact, :provider_options, %{})
          ] do
        assert :error = invalid |> Requirements.interim() |> Requirements.canonical()
      end
    end
  end

  describe "attested_public_model/2" do
    test "accepts only the exact bounded model value" do
      model = "provider:public-model"

      assert PtcRunner.LLM.attested_public_model(PublicModelAdapter, model) == model
      assert PtcRunner.LLM.attested_public_model(MismatchingPublicModelAdapter, model) == nil
      assert PtcRunner.LLM.attested_public_model(MockAdapter, model) == nil
    end

    test "treats adapter failures and malformed values as private" do
      assert PtcRunner.LLM.attested_public_model(RaisingPublicModelAdapter, "provider:model") ==
               nil

      invalid_utf8 = <<"provider:", 255>>
      assert PtcRunner.LLM.attested_public_model(PublicModelAdapter, invalid_utf8) == nil

      oversized = "provider:" <> String.duplicate("m", 256)
      assert PtcRunner.LLM.attested_public_model(PublicModelAdapter, oversized) == nil
    end

    test "the built-in adapter publishes ReqLLM targets but not direct HTTP targets" do
      adapter = PtcRunner.LLM.ReqLLMAdapter
      model = "openrouter:deepseek/deepseek-v4-flash-0731"

      assert PtcRunner.LLM.attested_public_model(adapter, model) == model
      assert PtcRunner.LLM.attested_public_model(adapter, "ollama:local-model") == nil

      assert PtcRunner.LLM.attested_public_model(
               adapter,
               "openai-compat:https://private.example/v1|deployment"
             ) == nil
    end
  end

  describe "adapter!/0" do
    test "returns configured adapter" do
      assert PtcRunner.LLM.adapter!() == MockAdapter
    end

    test "resolves to the packaged ReqLLMAdapter default" do
      Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.LLM.ReqLLMAdapter)
      assert PtcRunner.LLM.adapter!() == PtcRunner.LLM.ReqLLMAdapter
    end

    test "raises when no adapter is configured" do
      Application.delete_env(:ptc_runner, :llm_adapter)

      assert_raise RuntimeError, ~r/No LLM adapter configured/, fn ->
        PtcRunner.LLM.adapter!()
      end
    end

    test "raises with actionable message when configured adapter cannot be loaded" do
      Application.put_env(:ptc_runner, :llm_adapter, NonExistent.Adapter)

      assert_raise RuntimeError, ~r/req_llm/, fn ->
        PtcRunner.LLM.adapter!()
      end
    end
  end

  defp captured_warning(message) do
    ExUnit.CaptureIO.capture_io(:stderr, fn -> IO.warn(message, []) end)
  end
end
