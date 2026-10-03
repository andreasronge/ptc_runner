defmodule PtcRunner.Kernel.DecisionHTTPHostTest do
  use ExUnit.Case, async: false
  @moduletag :operator

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.LLMReplay
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.TestSupport.DecisionHTTPFixture
  alias PtcRunner.TestSupport.HostInstallationFixtures

  @example Path.expand("../../../examples/decision-refund-triage", __DIR__)

  @tag :tmp_dir
  test "ptc run records HTTP measurements, zero cost and served identity", %{
    tmp_dir: dir
  } do
    response = %{
      "model" => "served-v2",
      "answers" => %{"q" => %{"type" => "boolean", "probability" => 0.9, "confidence" => 0.8}},
      "usage" => %{"input_tokens" => 10, "output_tokens" => 2, "cost" => 0}
    }

    fixture = DecisionHTTPFixture.start(response, self())
    on_exit(fn -> DecisionHTTPFixture.stop(fixture) end)
    File.cp_r!(@example, dir)
    File.rm_rf!(Path.join(dir, ".ptc"))
    manifest_path = Path.join(dir, "ptc.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()

    manifest =
      put_in(manifest, ["input", "value"], %{
        "state" => %{},
        "questions" => %{
          "q" => %{"type" => "boolean", "instructions" => "Does the state meet the condition?"}
        }
      })

    File.write!(manifest_path, Jason.encode!(manifest))

    File.write!(Path.join(dir, "workflow.clj"), """
    (ns example.decision)
    (defn run [request] (return (decision/request request)))
    """)

    File.write!(
      Path.join(dir, "ptc-host.json"),
      Jason.encode!(%{
        "limits" => %{"llm_cost_microusd" => 20_000, "llm_total_tokens" => 9000},
        "install" => %{
          "frozen-decisions" => %{
            "source" => "decision",
            "backend" => "http",
            "endpoint" => fixture.endpoint,
            "allow_insecure_loopback" => true,
            "model" => "declared",
            "usage_guarantees" => %{"tokens" => true, "cost_currency" => "USD"},
            "installation_revision" => "decision-v1",
            "max_total_tokens_per_call" => 8000,
            "max_cost_per_call" => %{"currency" => "USD", "amount" => "0"}
          }
        }
      })
    )

    assert {:ok, _doctor} =
             CommandEngine.dispatch([
               "doctor",
               Path.join(dir, "ptc.json"),
               "--host-config",
               Path.join(dir, "ptc-host.json"),
               "--connect"
             ])

    refute_received {:decision_http_request, _, _}
    {:ok, host} = HostConfig.load(Path.join(dir, "ptc-host.json"))
    {:ok, catalog} = HostInstallation.catalog(host)
    {:ok, registry} = HostInstallation.runtime_registry(host, catalog)
    on_exit(fn -> InstallationCatalog.close(catalog) end)
    context = HostInstallationFixtures.context(dir, :workflow)

    assert {:ok, built} =
             ProviderRegistry.build(registry, "frozen-decisions", %{}, context)

    assert built.snapshot["acquisition"] == %{
             "source" => "decision",
             "backend" => "http",
             "model" => "declared"
           }

    refute inspect(built.snapshot) =~ fixture.endpoint

    assert {:error, :provider_destination_denied} =
             ProviderRegistry.prepare(registry, "frozen-decisions", %{}, %{
               context
               | destination: :mission
             })

    assert {:ok, outcome} = CommandEngine.dispatch(["run", Path.join(dir, "ptc-project.json")])
    result = outcome.envelope["result"]["value"]

    assert result == response
    assert_receive {:decision_http_request, headers, request}
    refute String.contains?(String.downcase(headers), "authorization:")
    assert request["model"] == "declared"
    assert request["state"] == %{}
    assert request["questions"]["q"]["type"] == "boolean"
    usage = outcome.envelope["execution"]["usage"]
    assert usage["llm_budget"]["cost"]["charged_microusd"] == 0
    assert usage["llm_budget"]["total_tokens"]["charged"] == 12
    assert usage["capability_calls"] == %{"workflow/decision-request" => 1}

    {:ok, request_hash} = LLMReplay.request_hash(Map.drop(request, ["model"]))

    File.write!(
      Path.join(dir, "http-replay.jsonl"),
      Jason.encode!(%{
        "schema_version" => 2,
        "request_hash" => request_hash,
        "response" => response
      }) <> "\n"
    )

    File.write!(
      Path.join(dir, "ptc-host.json"),
      Jason.encode!(%{
        "install" => %{
          "frozen-decisions" => %{
            "source" => "decision_replay",
            "fixtures" => "http-replay.jsonl",
            "installation_revision" => "replay-v1",
            "usage_guarantees" => %{"tokens" => true, "cost_currency" => nil},
            "max_total_tokens_per_call" => 8000,
            "max_cost_per_call" => %{"currency" => "USD", "amount" => "0"}
          }
        }
      })
    )

    assert {:ok, replayed} = CommandEngine.dispatch(["run", Path.join(dir, "ptc-project.json")])
    assert replayed.envelope["result"]["value"] == response

    assert {:ok, trace} =
             TraceSnapshot.start({:directory, Path.join(dir, ".ptc/traces")}, owner: self())

    assert {:ok, inspection} =
             InspectionSnapshot.start({:directory, Path.join(dir, ".ptc/inspection")}, trace,
               owner: self()
             )

    on_exit(fn ->
      InspectionSnapshot.stop(inspection)
      TraceSnapshot.stop(trace)
    end)

    assert {:ok, row} =
             TraceSnapshot.query(trace, :get_run, %{"run_id" => outcome.envelope["run_ref"]})

    assert row["decision_calls"] == 1
    assert row["llm_calls"] == 0

    assert {:ok, page} =
             InspectionSnapshot.query(inspection, :model_exchanges, %{
               "run_id" => outcome.envelope["run_ref"]
             })

    assert [exchange] = page["items"]
    assert exchange["served_model"] == "served-v2"
    assert exchange["request_hash"] == request_hash
  end
end
