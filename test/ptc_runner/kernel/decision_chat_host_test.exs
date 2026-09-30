defmodule PtcRunner.Kernel.DecisionChatHostTest do
  use ExUnit.Case, async: false
  @moduletag :operator

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.TraceSnapshot

  @example Path.expand("../../../examples/decision-refund-triage", __DIR__)

  setup do
    settings = [
      llm_adapter: PtcRunner.TestSupport.HostLLMAdapter,
      host_llm_test_owner: self(),
      host_llm_test_public_model: true,
      host_llm_test_result:
        {:ok, %{object: %{"q" => false}, tokens: %{input: 10, output: 2, total_cost: 0.0002}}}
    ]

    previous =
      Map.new(settings, fn {key, _} -> {key, Application.fetch_env(:ptc_runner, key)} end)

    for {key, value} <- settings, do: Application.put_env(:ptc_runner, key, value)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:ptc_runner, key, value)
          :error -> Application.delete_env(:ptc_runner, key)
        end
      end
    end)
  end

  @tag :tmp_dir
  test "ptc run uses an installed chat callback once and records only a decision exchange", %{
    tmp_dir: dir
  } do
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
        "credentials" => %{"key" => %{"literal" => "fixture-key"}},
        "install" => %{
          "chat" => %{
            "source" => "llm",
            "model" => "fixture:chat",
            "credential" => "key",
            "structured_output_mode" => "json_schema",
            "installation_revision" => "chat-v1",
            "reservation_tariff" => %{"currency" => "USD", "id" => "fixture"},
            "usage_guarantees" => %{"tokens" => true, "cost_currency" => "USD"}
          },
          "frozen-decisions" => %{
            "source" => "decision",
            "backend" => "chat",
            "llm" => "chat",
            "installation_revision" => "decision-v1",
            "max_total_tokens_per_call" => 8000,
            "max_cost_per_call" => %{"currency" => "USD", "amount" => "0.01"}
          }
        }
      })
    )

    assert {:ok, outcome} = CommandEngine.dispatch(["run", Path.join(dir, "ptc-project.json")])
    result = outcome.envelope["result"]["value"]

    assert result["answers"]["q"] == %{
             "type" => "boolean",
             "value" => false,
             "probability" => nil,
             "confidence" => nil
           }

    assert result["model"] == "fixture:chat"
    assert_receive {:host_llm_request, "fixture:chat", request}
    assert request.credential == "fixture-key"
    assert request.schema["properties"]["q"] == %{"type" => "boolean"}
    assert is_integer(request.llm_request_deadline_ms)
    refute_receive {:host_llm_request, _, _}
    usage = outcome.envelope["execution"]["usage"]
    assert usage["llm_budget"]["cost"]["charged_microusd"] == 200
    assert usage["llm_budget"]["total_tokens"]["charged"] == 12
    assert usage["capability_calls"] == %{"workflow/decision-request" => 1}

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
    assert exchange["request_hash"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
  end
end
