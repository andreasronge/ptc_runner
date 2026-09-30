defmodule PtcRunner.Kernel.DecisionExampleTest do
  use ExUnit.Case, async: true
  @moduletag :operator
  alias PtcRunner.Kernel.ChatDecisions
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.LLMReplay
  alias PtcRunner.Kernel.TraceSnapshot

  @example Path.expand("../../../examples/decision-refund-triage", __DIR__)

  @tag :tmp_dir
  test "ptc run replays decisions as hashed model exchanges", %{tmp_dir: dir} do
    project = copy_example(dir)
    assert {:ok, outcome} = CommandEngine.dispatch(["run", project])
    assert outcome.envelope["result"]["value"]["refund_ticket_ids"] == ["T-1001", "T-1004"]
    assert outcome.envelope["result"]["value"]["decisions"]["T_1001"]["probability"] == 0.95
    assert outcome.envelope["execution"]["usage"]["llm_spend"]["total_cost"]["microunits"] == 28
    artifacts = Path.join(Path.dirname(project), ".ptc")

    assert {:ok, trace} =
             TraceSnapshot.start({:directory, Path.join(artifacts, "traces")}, owner: self())

    assert {:ok, row} =
             TraceSnapshot.query(trace, :get_run, %{"run_id" => outcome.envelope["run_ref"]})

    assert row["decision_calls"] == 1
    assert row["llm_calls"] == 0

    assert {:ok, inspection} =
             InspectionSnapshot.start({:directory, Path.join(artifacts, "inspection")}, trace,
               owner: self()
             )

    on_exit(fn ->
      InspectionSnapshot.stop(inspection)
      TraceSnapshot.stop(trace)
    end)

    assert {:ok, page} =
             InspectionSnapshot.query(inspection, :model_exchanges, %{
               "run_id" => outcome.envelope["run_ref"]
             })

    [trace_path] = Path.wildcard(Path.join([artifacts, "traces", "*.jsonl"]))

    events =
      trace_path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    stopped =
      Enum.find(
        events,
        &(&1["type"] == "capability-stopped" and &1["data"]["name"] == "decision-request")
      )

    assert stopped["data"]["served_model"] == "typesafe/jev-1.13-20260917"
    assert [exchange] = page["items"]
    assert exchange["request_hash"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert exchange["served_model"] == "typesafe/jev-1.13-20260917"
    assert exchange["result"]["value"]["model"] == "typesafe/jev-1.13-20260917"
  end

  @tag :tmp_dir
  test "replay honors the host reservation bound before dispatch", %{tmp_dir: dir} do
    project = copy_example(dir)
    host = Path.join(Path.dirname(project), "ptc-host.json")

    config =
      host |> File.read!() |> Jason.decode!() |> Map.put("limits", %{"llm_cost_microusd" => 9999})

    File.write!(host, Jason.encode!(config))
    assert {:error, outcome} = CommandEngine.dispatch(["run", project])
    assert outcome.exit_status == 6
    assert outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
  end

  for {scenario, response_patch, cost, tokens, model} <- [
        {:cost_overrun,
         %{"usage" => %{"input_tokens" => 300, "output_tokens" => 30, "cost" => 0.02}}, 20_000,
         330, "typesafe/jev-1.13-20260917"},
        {:token_overrun,
         %{"usage" => %{"input_tokens" => 9000, "output_tokens" => 10, "cost" => 0.000028}}, 28,
         9010, "typesafe/jev-1.13-20260917"},
        {:rejected_answer, %{"answers" => %{}}, 28, 330, "typesafe/jev-1.13-20260917"},
        {:invalid_model, %{"model" => ""}, 28, 330, nil}
      ] do
    @tag :tmp_dir
    test "decision replay retains response evidence for #{scenario}", %{tmp_dir: dir} do
      project = copy_example(dir)
      directory = Path.dirname(project)
      host_path = Path.join(directory, "ptc-host.json")

      host =
        host_path
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("limits", %{"llm_cost_microusd" => 100_000, "llm_total_tokens" => 20_000})

      File.write!(host_path, Jason.encode!(host))
      fixture_path = Path.join(directory, "replay.jsonl")

      fixture =
        fixture_path
        |> File.read!()
        |> Jason.decode!()
        |> update_in(["response"], &Map.merge(&1, unquote(Macro.escape(response_patch))))

      File.write!(fixture_path, Jason.encode!(fixture) <> "\n")
      assert {:error, outcome} = CommandEngine.dispatch(["run", project])
      usage = outcome.envelope["execution"]["usage"]
      assert usage["llm_budget"]["cost"]["charged_microusd"] == unquote(cost)
      assert usage["llm_budget"]["total_tokens"]["charged"] == unquote(tokens)
      assert usage["capability_calls"]["workflow/decision-request"] == 1
      artifacts = Path.join(directory, ".ptc")
      [trace_path] = Path.wildcard(Path.join([artifacts, "traces", "*.jsonl"]))

      stopped =
        trace_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(
          &(&1["type"] == "capability-stopped" and &1["data"]["name"] == "decision-request")
        )

      assert stopped["data"]["served_model"] == unquote(model)
      assert stopped["data"]["status"] == "error"

      assert {:ok, trace} =
               TraceSnapshot.start({:directory, Path.join(artifacts, "traces")}, owner: self())

      assert {:ok, inspection} =
               InspectionSnapshot.start({:directory, Path.join(artifacts, "inspection")}, trace,
                 owner: self()
               )

      on_exit(fn ->
        InspectionSnapshot.stop(inspection)
        TraceSnapshot.stop(trace)
      end)

      assert {:ok, page} =
               InspectionSnapshot.query(inspection, :model_exchanges, %{
                 "run_id" => outcome.envelope["run_ref"]
               })

      assert [exchange] = page["items"]
      assert exchange["served_model"] == unquote(model)
      assert exchange["result"]["status"] == "error"

      assert exchange["result"]["reason"] ==
               unquote(
                 if scenario in [:cost_overrun, :token_overrun],
                   do: "invalid_result",
                   else: "output_schema_mismatch"
               )

      assert exchange["result"]["retryable?"] == false
      refute Map.has_key?(exchange["result"], "value")
    end
  end

  @tag :tmp_dir
  test "replay accepts costless usage with the corresponding live guarantee", %{tmp_dir: dir} do
    project = copy_example(dir)
    directory = Path.dirname(project)
    host_path = Path.join(directory, "ptc-host.json")
    host = host_path |> File.read!() |> Jason.decode!()

    host =
      put_in(host, ["install", "frozen-decisions", "usage_guarantees"], %{
        "tokens" => true,
        "cost_currency" => nil
      })

    File.write!(host_path, Jason.encode!(host))
    fixture_path = Path.join(directory, "replay.jsonl")
    fixture = fixture_path |> File.read!() |> Jason.decode!()
    fixture = update_in(fixture, ["response", "usage"], &Map.delete(&1, "cost"))
    File.write!(fixture_path, Jason.encode!(fixture) <> "\n")
    assert {:ok, outcome} = CommandEngine.dispatch(["run", project])
    assert outcome.envelope["result"]["value"]["refund_ticket_ids"] == ["T-1001", "T-1004"]
  end

  @tag :tmp_dir
  test "one manifest handles measured and discrete replay answers and can require measurement", %{
    tmp_dir: dir
  } do
    project = copy_example(dir)
    directory = Path.dirname(project)
    manifest_path = Path.join(directory, "ptc.json")

    request = %{
      "state" => %{},
      "questions" => %{
        "q" => %{"type" => "boolean", "instructions" => "Does the state meet the condition?"}
      }
    }

    manifest = manifest_path |> File.read!() |> Jason.decode!()
    manifest = put_in(manifest, ["input", "value"], request)
    File.write!(manifest_path, Jason.encode!(manifest))
    manifest_bytes = File.read!(manifest_path)

    File.write!(Path.join(directory, "workflow.clj"), """
    (ns example.decision)
    (defn run [request]
      (let [response (decision/request request)
            answer (get-in response ["answers" "q"])
            probability (get answer "probability")
            value (get answer "value")]
        (return {"use_available" (if (nil? probability)
                                   (if (nil? value) "escalate" value)
                                   (>= probability 0.5))
                 "require_measured" (if (nil? probability) "escalate" (>= probability 0.5))})))
    """)

    {:ok, hash} = LLMReplay.request_hash(request)

    for discrete <- [true, false] do
      measured = %{
        "model" => "measured",
        "answers" => %{
          "q" => %{
            "type" => "boolean",
            "probability" => if(discrete, do: 0.9, else: 0.1),
            "confidence" => nil
          }
        },
        "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
      }

      chat =
        ChatDecisions.requester(
          fn _, _ ->
            {:ok, %{object: %{"q" => discrete}, tokens: %{input: 10, output: 2}}}
          end,
          "chat"
        )

      {:ok, unmeasured} = chat.(request, %{})

      for {response, required} <- [{measured, discrete}, {unmeasured, "escalate"}] do
        host_path = Path.join(directory, "ptc-host.json")
        host = host_path |> File.read!() |> Jason.decode!()

        host =
          put_in(host, ["install", "frozen-decisions", "usage_guarantees"], %{
            "tokens" => true,
            "cost_currency" => nil
          })

        File.write!(host_path, Jason.encode!(host))

        File.write!(
          Path.join(directory, "replay.jsonl"),
          Jason.encode!(%{
            "schema_version" => 2,
            "request_hash" => hash,
            "response" => response
          }) <> "\n"
        )

        assert {:ok, outcome} = CommandEngine.dispatch(["run", project])

        assert outcome.envelope["result"]["value"] == %{
                 "use_available" => discrete,
                 "require_measured" => required
               }

        assert File.read!(manifest_path) == manifest_bytes
      end
    end
  end

  defp copy_example(dir) do
    dest = Path.join(dir, "example")
    File.cp_r!(@example, dest)
    File.rm_rf!(Path.join(dest, ".ptc"))
    Path.join(dest, "ptc-project.json")
  end
end
