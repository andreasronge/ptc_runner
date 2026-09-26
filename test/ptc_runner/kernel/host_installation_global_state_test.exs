defmodule PtcRunner.Kernel.HostInstallationGlobalStateTest do
  # async: false — these cases set :ptc_runner :llm_adapter (and :req_llm) app env, stop
  # :req_llm, or capture :stderr. The rest of HostInstallation coverage is async
  # in HostInstallationTest.
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.HostInstallationFixtures

  alias PtcRunner.Kernel.DoctorPlan
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderCallAdmission
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSnapshot
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.TestSupport.LLMSupport

  defmodule MismatchedContractAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def prepare_model(model, requirements) do
      {:ok, %{selector: model}, :unavailable,
       %{requirements | structured_output_mode: :json_schema}}
    end

    @impl true
    def call(_target, _invocation), do: raise("a mismatched contract must not reach call/2")
  end

  defmodule UnsupportedContractAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def prepare_model(_model, _requirements), do: {:error, :unsupported_model_option}

    @impl true
    def call(_target, _invocation), do: raise("an unsupported contract must not reach call/2")
  end

  defmodule PreparingHostLLMAdapter do
    @behaviour PtcRunner.LLM

    alias PtcRunner.LLM.Invocation

    @impl true
    def prepare_model(model, requirements) do
      send(Application.fetch_env!(:ptc_runner, :host_preparing_llm_owner), {:prepared, model})
      {:ok, {:prepared, model, requirements.exact_options}, :uncataloged, requirements}
    end

    @impl true
    def call({:prepared, model, _exact_options}, %Invocation{} = invocation) do
      send(Application.fetch_env!(:ptc_runner, :host_preparing_llm_owner), {
        :prepared_request,
        model,
        invocation.request
      })

      {:ok, %{content: "ok", tokens: %{}}}
    end
  end

  @tag :tmp_dir
  test "connectivity probes reject runtime services from another host", %{tmp_dir: dir} do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    previous_owner = Application.get_env(:ptc_runner, :host_llm_test_owner)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)
      restore_env(:host_llm_test_owner, previous_owner)
    end)

    live_config = %{
      "credentials" => %{"key" => %{"literal" => "host-a-secret"}},
      "install" => %{
        "live" => %{
          "source" => "llm",
          "structured_output_mode" => "unsupported",
          "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
          "installation_revision" => "live-v1",
          "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
          "credential" => "key"
        }
      }
    }

    host_a = load_host(Path.join(dir, "a"), live_config)

    host_b =
      live_config
      |> put_in(["credentials", "key", "literal"], "host-b-secret")
      |> then(&load_host(Path.join(dir, "b"), &1))

    assert {:ok, catalog_a} = HostInstallation.catalog(host_a)
    assert {:ok, services_b} = HostInstallation.runtime_services(host_b)
    descriptor = catalog_a.descriptors["live"]
    implementation = catalog_a.implementations["live"]
    probe_context = context(dir, :workflow)

    assert {:ok, selection} =
             SelectionRules.normalize(descriptor.selection_rules, %{}, probe_context.limits)

    assert {:error, :invalid_provider_runtime_services} =
             implementation.connectivity_probe.(selection, probe_context, services_b)

    refute_receive {:host_llm_request, _, _}
  end

  @tag :tmp_dir
  test "audited local preflight matches missing LLM adapters and stdio runtime files", %{
    tmp_dir: dir
  } do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.MissingLLMAdapter)

    on_exit(fn -> restore_env(:llm_adapter, previous_adapter) end)

    llm_host =
      load_host(dir, %{
        "credentials" => %{"key" => %{"literal" => "not-read"}},
        "install" => %{
          "live" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "live-v1",
            "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
            "credential" => "key"
          }
        }
      })

    assert_local_preflight_parity(llm_host, "live", :workflow, {:error, :invalid_llm_model})

    missing_executable_host =
      stdio_config("/definitely/missing-ptc-server")
      |> put_in(["runtime", "stdio_launcher"], System.find_executable("sh"))
      |> then(&load_host(Path.join(dir, "missing-executable"), &1))

    assert_local_preflight_parity(
      missing_executable_host,
      "workspace",
      :mission,
      {:error, :mcp_command_not_found}
    )

    missing_launcher_host =
      stdio_config(System.find_executable("sh"))
      |> put_in(["runtime", "stdio_launcher"], "/definitely/missing-ptc-launcher")
      |> then(&load_host(Path.join(dir, "missing-launcher"), &1))

    assert_local_preflight_parity(
      missing_launcher_host,
      "workspace",
      :mission,
      {:error, :mcp_stdio_launcher_unavailable}
    )
  end

  @tag :tmp_dir
  test "installs live LLM aliases with adapter-attested model identity", %{
    tmp_dir: dir
  } do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    previous_owner = Application.get_env(:ptc_runner, :host_llm_test_owner)
    previous_public_model = Application.get_env(:ptc_runner, :host_llm_test_public_model)
    previous_public_model_owner = Application.get_env(:ptc_runner, :host_llm_public_model_owner)

    previous_provider_application_owner =
      Application.get_env(:ptc_runner, :host_llm_provider_application_owner)

    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())
    Application.put_env(:ptc_runner, :host_llm_test_public_model, true)
    Application.put_env(:ptc_runner, :host_llm_public_model_owner, self())
    Application.put_env(:ptc_runner, :host_llm_provider_application_owner, self())

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)
      restore_env(:host_llm_test_owner, previous_owner)
      restore_env(:host_llm_test_public_model, previous_public_model)
      restore_env(:host_llm_public_model_owner, previous_public_model_owner)
      restore_env(:host_llm_provider_application_owner, previous_provider_application_owner)
    end)

    config = %{
      "credentials" => %{"openrouter_key" => %{"literal" => "test-llm-secret"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "structured_output_mode" => "unsupported",
          "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
          "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
          "credential" => "openrouter_key",
          "params" => %{
            "temperature" => 0.15,
            "seed" => 73,
            "max_tokens" => 2_048,
            "top_p" => 0.9,
            "presence_penalty" => -0.5,
            "frequency_penalty" => 0.75,
            "reasoning_effort" => "medium"
          },
          "installation_revision" => "model-policy-v2",
          "accepts_data" => ["normal", "private_inspection"],
          "ceilings" => %{
            "max_request_bytes" => 200_000,
            "max_response_bytes" => 300_000
          }
        }
      }
    }

    host = load_host(dir, config)

    assert {:ok, catalog} = HostInstallation.catalog(host)

    assert {:ok,
            [
              %{
                "alias" => "deepseek",
                "source" => "llm",
                "installation_revision" => "model-policy-v2",
                "default" => nil,
                "selected" => false
              }
            ]} = DoctorPlan.model_aliases(catalog, nil)

    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)

    workflow = context(dir, :workflow)

    assert {:ok, prepared} =
             ProviderRegistry.prepare(
               registry,
               "deepseek",
               %{"max_request_bytes" => 100_000},
               workflow
             )

    assert prepared.credential_names == ["openrouter_key"]

    assert prepared.workflow_llm_route == %{
             source: "llm",
             installation_revision: "model-policy-v2",
             default: false,
             max_calls: 128,
             structured_output_mode: :unsupported,
             usage_guarantees: %{tokens: false, cost_currency: nil},
             reservation_tariff: nil,
             request_timeout_ms: 120_000
           }

    assert {:error, :provider_destination_denied} =
             ProviderRegistry.prepare(registry, "deepseek", %{}, %{
               workflow
               | destination: :mission
             })

    assert {:error, :invalid_llm_selection} =
             ProviderRegistry.prepare(
               registry,
               "deepseek",
               %{"max_response_bytes" => 300_001},
               workflow
             )

    assert {:error, :invalid_llm_selection} =
             ProviderRegistry.prepare(
               registry,
               "deepseek",
               %{"default" => "yes"},
               workflow
             )

    assert {:error, :invalid_llm_selection} =
             ProviderRegistry.prepare(
               registry,
               "deepseek",
               %{"max_calls" => 2_049},
               workflow
             )

    assert {:ok, preflighted} = ProviderRegistry.preflight(prepared)

    assert {:ok, credentials} =
             ProviderRegistry.resolve_credentials(registry, prepared.credential_names)

    assert credentials == %{"openrouter_key" => "test-llm-secret"}
    assert {:ok, built} = ProviderRegistry.acquire(preflighted, credentials)

    assert_receive {:host_llm_public_model, "openrouter:deepseek/deepseek-v4-flash-0731"}

    assert [%{name: "llm-request"} = capability] = built.capabilities
    assert built.accepts_data == [:normal, :private_inspection]
    assert built.data_class == :normal
    assert built.snapshot["provider"] == "deepseek"

    assert built.snapshot["acquisition"] == %{
             "source" => "llm",
             "resolved_model" => "openrouter:deepseek/deepseek-v4-flash-0731"
           }

    assert built.snapshot["declaration"] == %{
             "name" => "deepseek",
             "source" => "llm",
             "installation_revision" => "model-policy-v2",
             "data_class" => "normal",
             "accepts_data" => ["normal", "private_inspection"],
             "authorization_mode" => "none",
             "config" => %{
               "default" => false,
               "max_request_bytes" => 100_000,
               "max_response_bytes" => 300_000,
               "max_calls" => 128
             }
           }

    assert built.snapshot["acquisition_identity_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    assert built.snapshot["snapshot_hash"] =~ ~r/\A[0-9a-f]{64}\z/

    assert built.snapshot["installation_config_digest"] ==
             host.install["deepseek"].installation_config_digest

    refute inspect(built.snapshot) =~ "test-llm-secret"

    assert {:ok,
            %{
              alias: "deepseek",
              installation_revision: "model-policy-v2",
              resolved_model: "openrouter:deepseek/deepseek-v4-flash-0731"
            }} = ProviderSnapshot.llm_identity(built.snapshot)

    assert {:ok, response} =
             capability.callback.(
               %{
                 "messages" => [%{"role" => "user", "content" => "hello"}],
                 "cache" => true
               },
               LLMSupport.llm_context()
             )

    assert response["content"] == "ok"

    assert_receive {:host_llm_request, "openrouter:deepseek/deepseek-v4-flash-0731", request}
    assert_receive {:host_llm_provider_application, "openrouter:deepseek/deepseek-v4-flash-0731"}
    assert request.credential == "test-llm-secret"
    assert request.cache == false
    assert request.exact_options.temperature == 0.15
    assert request.exact_options.seed == 73
    assert request.exact_options.max_tokens == 2_048
    assert request.exact_options.top_p == 0.9
    assert request.exact_options.presence_penalty == -0.5
    assert request.exact_options.frequency_penalty == 0.75
    assert request.exact_options.reasoning_effort == :medium
    assert request.llm_request_deadline_ms == nil

    Application.put_env(:ptc_runner, :host_llm_test_public_model, false)
    private_host = load_host(Path.join(dir, "private"), config)
    assert {:ok, private_catalog} = HostInstallation.catalog(private_host)

    assert {:ok, private_registry} =
             HostInstallation.runtime_registry(private_host, private_catalog)

    assert {:ok, private_prepared} =
             ProviderRegistry.prepare(private_registry, "deepseek", %{}, context(dir, :workflow))

    assert {:ok, private_preflighted} = ProviderRegistry.preflight(private_prepared)

    assert {:ok, private_credentials} =
             ProviderRegistry.resolve_credentials(
               private_registry,
               private_prepared.credential_names
             )

    assert {:ok, private_built} =
             ProviderRegistry.acquire(private_preflighted, private_credentials)

    assert_receive {:host_llm_public_model, "openrouter:deepseek/deepseek-v4-flash-0731"}
    assert private_built.snapshot["acquisition"] == %{"source" => "llm"}
    refute Map.has_key?(private_built.snapshot["acquisition"], "resolved_model")
    assert :error = ProviderSnapshot.llm_identity(private_built.snapshot)
  end

  @tag :tmp_dir
  test "live LLM preparation seals the authorized output-token minimum", %{tmp_dir: dir} do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    previous_owner = Application.get_env(:ptc_runner, :host_llm_test_owner)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)
      restore_env(:host_llm_test_owner, previous_owner)
    end)

    host =
      load_host(dir, %{
        "credentials" => %{"openrouter_key" => %{"literal" => "test-llm-secret"}},
        "install" => %{
          "deepseek" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
            "credential" => "openrouter_key",
            "params" => %{"max_tokens" => 2_048},
            "installation_revision" => "model-policy-v2"
          }
        }
      })

    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)
    {:ok, narrowed} = Limits.new(%{llm_request_output_tokens: 100})
    workflow = context(dir, :workflow) |> Map.put(:limits, narrowed)

    assert {:ok, prepared} = ProviderRegistry.prepare(registry, "deepseek", %{}, workflow)
    assert {:ok, preflighted} = ProviderRegistry.preflight(prepared)

    assert {:ok, credentials} =
             ProviderRegistry.resolve_credentials(registry, prepared.credential_names)

    assert {:ok, built} = ProviderRegistry.acquire(preflighted, credentials)
    assert [%{callback: requester}] = built.capabilities

    assert {:ok, %{"content" => "ok"}} =
             requester.(
               %{"messages" => [%{"role" => "user", "content" => "hello"}]},
               LLMSupport.llm_context()
             )

    assert_receive {:host_llm_request, "openrouter:deepseek/deepseek-v4-flash-0731", request}
    assert request.exact_options.max_tokens == 100
    assert request.output_limit_bindings == [:application_limit]
    refute inspect(built.snapshot) =~ "max_tokens"
    refute inspect(built.snapshot) =~ "exact_options"
  end

  @tag :tmp_dir
  test "hosted Vertex admission rejects unattestable token ownership without dispatch", %{
    tmp_dir: dir
  } do
    LLMSupport.admit_provider_application!()
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    previous_vertex = Application.fetch_env(:req_llm, :google_vertex)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.LLM.ReqLLMAdapter)

    Application.put_env(:req_llm, :google_vertex,
      project_id: "test-project",
      access_token: "test-token",
      region: "global"
    )

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)

      case previous_vertex do
        {:ok, value} -> Application.put_env(:req_llm, :google_vertex, value)
        :error -> Application.delete_env(:req_llm, :google_vertex)
      end
    end)

    host =
      load_host(dir, %{
        "credentials" => %{"key" => %{"literal" => "test-key"}},
        "install" => %{
          "vertex" => %{
            "source" => "llm",
            "model" => "google_vertex:gemini-test-model",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "credential" => "key",
            "installation_revision" => "vertex-v1",
            "params" => %{"max_tokens" => 100}
          }
        }
      })

    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)

    assert {:ok, %{capabilities: [_]}} =
             ProviderRegistry.build(registry, "vertex", %{}, context(dir, :workflow))

    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 2, max_waiters: 0})

    assert {:ok, services} =
             HostInstallation.runtime_services(host, provider_call_admission: admission)

    assert {:ok, hosted_registry} = InstallationCatalog.runtime_registry(catalog, services)
    hosted_context = context(dir, :workflow)

    construction = ProviderRegistry.build(hosted_registry, "vertex", %{}, hosted_context)

    assert {:ok, %{active: 0, status: :ready}} = ProviderCallAdmission.snapshot(admission)
    descriptor = catalog.descriptors["vertex"]

    assert {:ok, selection} =
             SelectionRules.normalize(descriptor.selection_rules, %{}, hosted_context.limits)

    probe_context = Map.put(hosted_context, :credentials, %{"key" => "test-key"})

    readiness =
      catalog.implementations["vertex"].connectivity_probe.(selection, probe_context, services)

    assert {construction, readiness} ==
             {{:error, :provider_admission_unavailable},
              {:error, :provider_admission_unavailable}}

    assert {:ok, %{active: 0, status: :ready}} = ProviderCallAdmission.snapshot(admission)
    InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "an unsupported model contract fails local preflight before credentials", %{tmp_dir: dir} do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    Application.put_env(:ptc_runner, :llm_adapter, UnsupportedContractAdapter)

    on_exit(fn -> restore_env(:llm_adapter, previous_adapter) end)

    host =
      load_host(dir, %{
        "credentials" => %{"openrouter_key" => %{"literal" => "test-llm-secret"}},
        "install" => %{
          "deepseek" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
            "credential" => "openrouter_key",
            "installation_revision" => "model-policy-v2"
          }
        }
      })

    assert_local_preflight_parity(
      host,
      "deepseek",
      :workflow,
      {:error, :unsupported_model_option}
    )
  end

  @tag :tmp_dir
  test "a mismatched adapter attestation fails local preflight before credentials", %{
    tmp_dir: dir
  } do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    Application.put_env(:ptc_runner, :llm_adapter, MismatchedContractAdapter)

    on_exit(fn -> restore_env(:llm_adapter, previous_adapter) end)

    host =
      load_host(dir, %{
        "credentials" => %{"key" => %{"literal" => "test-llm-secret"}},
        "install" => %{
          "live" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "model" => "openrouter:test/model",
            "credential" => "key",
            "installation_revision" => "mismatch-v1"
          }
        }
      })

    assert_local_preflight_parity(
      host,
      "live",
      :workflow,
      {:error, :unsupported_model_option}
    )
  end

  @tag :tmp_dir
  test "a live LLM requester binds one prepared target across turns", %{tmp_dir: dir} do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    previous_owner = Application.get_env(:ptc_runner, :host_preparing_llm_owner)
    Application.put_env(:ptc_runner, :llm_adapter, PreparingHostLLMAdapter)
    Application.put_env(:ptc_runner, :host_preparing_llm_owner, self())

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)
      restore_env(:host_preparing_llm_owner, previous_owner)
    end)

    host =
      load_host(dir, %{
        "credentials" => %{"key" => %{"literal" => "test-secret"}},
        "install" => %{
          "live" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "live-v1",
            "model" => "provider:future-model",
            "credential" => "key"
          }
        }
      })

    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)

    assert {:ok, prepared} =
             ProviderRegistry.prepare(registry, "live", %{}, context(dir, :workflow))

    assert {:ok, preflighted} = ProviderRegistry.preflight(prepared)
    assert_receive {:prepared, "provider:future-model"}
    refute_receive {:prepared, _model}
    assert {:ok, credentials} = ProviderRegistry.resolve_credentials(registry, ["key"])

    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, built} = ProviderRegistry.acquire(preflighted, credentials)
        assert [%{callback: requester}] = built.capabilities

        for content <- ["first", "second"] do
          assert {:ok, %{"content" => "ok"}} =
                   requester.(
                     %{
                       "messages" => [%{"role" => "user", "content" => content}]
                     },
                     LLMSupport.llm_context()
                   )
        end
      end)

    assert length(Regex.scan(~r/model_uncataloged/, warning)) == 1
    refute warning =~ "provider:future-model"
    refute warning =~ "ReqLLM"
    refute_receive {:prepared, _model}
    assert_receive {:prepared_request, "provider:future-model", _request}
    assert_receive {:prepared_request, "provider:future-model", _request}
    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "live LLM connectivity probe makes exactly one bounded completion request", %{
    tmp_dir: dir
  } do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    previous_owner = Application.get_env(:ptc_runner, :host_llm_test_owner)
    previous_result = Application.get_env(:ptc_runner, :host_llm_test_result)
    previous_warm_words = Application.get_env(:ptc_runner, :host_llm_test_warm_words)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())
    Application.put_env(:ptc_runner, :host_llm_test_warm_words, 100_000)

    Application.put_env(
      :ptc_runner,
      :host_llm_test_result,
      {:ok,
       %{
         content: "ok",
         tokens: %{input: 8, output: 1, total_cost: %{currency: "USD", microunits: 3}}
       }}
    )

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)
      restore_env(:host_llm_test_owner, previous_owner)
      restore_env(:host_llm_test_result, previous_result)
      restore_env(:host_llm_test_warm_words, previous_warm_words)
    end)

    host =
      load_host(dir, %{
        "credentials" => %{"key" => %{"literal" => "probe-secret"}},
        "install" => %{
          "live" => %{
            "source" => "llm",
            "structured_output_mode" => "json_schema",
            "usage_guarantees" => %{"tokens" => true, "cost_currency" => "USD"},
            "installation_revision" => "live-v1",
            "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
            "credential" => "key",
            "params" => %{"max_tokens" => 99}
          }
        }
      })

    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, runtime_services} = HostInstallation.runtime_services(host)
    descriptor = catalog.descriptors["live"]
    implementation = catalog.implementations["live"]

    # Deliberately not the host document's literal. Phase-8 step 5 resolves the
    # credential once and hands it down, so the value the probe actually uses is
    # the supplied one; a probe that resolved its own would reach for the host
    # document and produce "probe-secret" instead.
    probe_context =
      dir
      |> context(:workflow)
      |> update_in([:limits], &Map.put(&1, :provider_heap_words, 20_000))
      |> Map.put(:credentials, %{"key" => "pre-resolved-secret"})

    assert is_binary(catalog.runtime_binding)
    assert descriptor.structured_output_mode == :json_schema
    assert descriptor.usage_guarantees == %{tokens: true, cost_currency: "USD"}
    assert descriptor.local_preflight == :audited_local
    assert descriptor.connectivity_mode == :probe
    assert descriptor.probe_effect == :completion
    assert is_function(implementation.local_preflight, 3)
    assert is_function(implementation.connectivity_probe, 3)

    assert {:ok, selection} =
             SelectionRules.normalize(descriptor.selection_rules, %{}, probe_context.limits)

    assert :ok =
             implementation.local_preflight.(selection, probe_context, runtime_services)

    # The probe bills a real request, so what the provider reported it spent
    # travels back with the success rather than being discarded.
    assert {:ok,
            %{
              "input" => 8,
              "output" => 1,
              "total_cost" => %{"currency" => "USD", "microunits" => 3}
            }} =
             implementation.connectivity_probe.(selection, probe_context, runtime_services)

    assert_receive {:host_llm_ensure_ready, warmup_pid}
    assert_receive {:host_llm_request, "openrouter:deepseek/deepseek-v4-flash-0731", request}
    request_pid = Map.fetch!(request, :probe_pid)
    refute warmup_pid == request_pid
    assert request.credential == "pre-resolved-secret"
    assert request.cache == false
    assert request.exact_options.max_tokens == 1
    assert is_integer(request.llm_request_deadline_ms)
    assert [%{role: :user, content: "Health check."}] = request.messages
    refute Map.has_key?(request, :schema)
    refute_receive {:host_llm_request, _, _}

    Application.put_env(
      :ptc_runner,
      :host_llm_test_result,
      {:ok, %{content: "ok"}}
    )

    assert {:error, :llm_connectivity_unavailable} =
             implementation.connectivity_probe.(selection, probe_context, runtime_services)

    assert_receive {:host_llm_request, "openrouter:deepseek/deepseek-v4-flash-0731", _request}
    refute_receive {:host_llm_request, _, _}

    Application.put_env(:ptc_runner, :host_llm_test_result, {:error, :unavailable})

    assert {:error, :llm_connectivity_unavailable} =
             implementation.connectivity_probe.(selection, probe_context, runtime_services)

    assert_receive {:host_llm_request, "openrouter:deepseek/deepseek-v4-flash-0731", _request}
    refute_receive {:host_llm_request, _, _}

    rejected =
      ProviderError.new(:authentication_failed, "rejected", dispatch_provenance: :dispatched)

    Application.put_env(:ptc_runner, :host_llm_test_result, {:error, rejected})

    assert {:error, ^rejected} =
             implementation.connectivity_probe.(selection, probe_context, runtime_services)

    assert_receive {:host_llm_request, "openrouter:deepseek/deepseek-v4-flash-0731", _request}
    refute_receive {:host_llm_request, _, _}

    # No fallback: the credential this installation declares is resolvable from
    # the host document, so a probe that still resolved its own would succeed
    # here rather than refuse. It refuses, and reaches no adapter at all.
    Application.put_env(:ptc_runner, :host_llm_test_result, nil)

    assert {:error, :llm_connectivity_unavailable} =
             implementation.connectivity_probe.(
               selection,
               Map.put(probe_context, :credentials, %{}),
               runtime_services
             )

    refute_receive {:host_llm_request, _, _}
    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "an unstarted provider application is a host misconfiguration, not an outage", %{
    tmp_dir: dir
  } do
    previous = %{
      adapter: Application.get_env(:ptc_runner, :llm_adapter),
      owner: Application.get_env(:ptc_runner, :host_llm_test_owner),
      result: Application.get_env(:ptc_runner, :host_llm_test_result),
      application: Application.get_env(:ptc_runner, :host_llm_test_provider_application)
    }

    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())
    Application.put_env(:ptc_runner, :host_llm_test_result, {:error, :transport_boom})

    # An e2e setup_all may have started :req_llm and left it running, which would
    # quietly dissolve this test's premise. Establish the stopped state rather
    # than assuming it, and put it back afterwards.
    req_llm_running? = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :req_llm))
    if req_llm_running?, do: Application.stop(:req_llm)

    on_exit(fn ->
      if req_llm_running?, do: Application.ensure_all_started(:req_llm)
    end)

    on_exit(fn ->
      restore_env(:llm_adapter, previous.adapter)
      restore_env(:host_llm_test_owner, previous.owner)
      restore_env(:host_llm_test_result, previous.result)
      restore_env(:host_llm_test_provider_application, previous.application)
    end)

    config = %{
      "credentials" => %{"key" => %{"literal" => "test-llm-secret"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "structured_output_mode" => "unsupported",
          "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
          "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
          "credential" => "key",
          "installation_revision" => "unstarted-v1"
        }
      }
    }

    host = load_host(dir, config)
    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)
    request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}

    build_capability = fn ->
      assert {:ok, %{capabilities: [capability]}} =
               ProviderRegistry.build(registry, "deepseek", %{}, context(dir, :workflow))

      capability
    end

    # An adapter whose backing application is not running: retrying cannot start
    # an OTP application, so the failure must name the real cause and be final.
    Application.put_env(
      :ptc_runner,
      :host_llm_test_provider_application,
      :req_llm
    )

    assert {:error, %PtcRunner.Kernel.ProviderError{} = stopped} =
             build_capability.().callback.(request, LLMSupport.llm_context())

    assert stopped.kind == :internal
    assert stopped.retryable? == false
    assert stopped.dispatch_provenance == :not_dispatched
    assert stopped.details =~ "req_llm"

    # A route declaring no backing application keeps the retryable transport
    # classification, so the check is not blanket.
    Application.put_env(:ptc_runner, :host_llm_test_provider_application, nil)

    assert {:error, %PtcRunner.Kernel.ProviderError{} = running} =
             build_capability.().callback.(request, LLMSupport.llm_context())

    assert running.kind == :unavailable
    assert running.retryable? == true

    # An application started and later stopped leaves the adapter raising rather
    # than returning an error tuple. The check must precede the call, or the
    # raise unwinds past it and the dispatcher reports a retryable failure.
    Application.put_env(:ptc_runner, :host_llm_test_raise, true)
    on_exit(fn -> Application.delete_env(:ptc_runner, :host_llm_test_raise) end)

    # Drop the probe messages the two invocations above produced, so the
    # refutation below can only observe a fresh adapter call.
    drain = fn drain ->
      receive do
        {:host_llm_request, _model, _request} -> drain.(drain)
      after
        0 -> :ok
      end
    end

    drain.(drain)

    Application.put_env(
      :ptc_runner,
      :host_llm_test_provider_application,
      :req_llm
    )

    assert {:error, %PtcRunner.Kernel.ProviderError{} = raised} =
             build_capability.().callback.(request, LLMSupport.llm_context())

    assert raised.kind == :internal
    assert raised.retryable? == false
    assert raised.dispatch_provenance == :not_dispatched
    refute_receive {:host_llm_request, _model, _request}
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_runner, key)

  defp restore_env(key, value), do: Application.put_env(:ptc_runner, key, value)
end
