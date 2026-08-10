defmodule PtcRunner.Kernel.ResultKeywordProjectionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.WorkflowEnvironment

  test "kernel JSON results project atom-backed and struct-backed keywords uniformly" do
    source =
      ~S|(return {:count 1 :zzz {:first 2} :items [:input :novel] :flags [nil true false]})|

    expected = %{
      "count" => 1,
      "zzz" => %{"first" => 2},
      "items" => ["input", "novel"],
      "flags" => [nil, true, false]
    }

    assert {:ok, %{value: ^expected}} = run(source, :json)
    assert {:ok, %{value: ^expected}} = run(source, :native)
  end

  test "kernel JSON results project runtime-built keywords and opaque programs" do
    assert {:ok, %{value: %{"count" => 1}}} =
             run(~S|(return (assoc {} :count 1))|, :json)

    assert {:ok,
            %{
              value: %{
                "program?" => true,
                "byte_size" => byte_size,
                "digest" => digest
              }
            }} = run(~S|(return (program (return 42)))|, :json)

    assert is_integer(byte_size) and byte_size > 0
    assert byte_size(digest) == 64
  end

  test "kernel JSON keyword projection preserves collision rejection and special values" do
    assert {:error, %{kind: :workflow_failed, reason: :public_projection_collision}} =
             run(~S|(return {:count 1 "count" 2})|, :json)

    for value <- ["##Inf", "##-Inf", "##NaN"] do
      assert {:error, %{kind: :workflow_failed, reason: :invalid_result_projection}} =
               run("(return #{value})", :json)
    end
  end

  test "keyword-keyed results receive a deterministic result hash" do
    assert {:ok, %{value: %{"count" => 1}}, events} = run_with_events(~S|(return {:count 1})|)

    assert %{data: %{result_hash: "sha256:" <> digest}} = List.last(events)
    assert byte_size(digest) == 64
  end

  test "result-contract callbacks validate the kernel JSON projection and reject stale requests" do
    assert {:ok, contract} =
             ValueContract.compile(%{
               "type" => "object",
               "additionalProperties" => false,
               "required" => ["state"],
               "properties" => %{"state" => %{"type" => "string", "const" => "count"}}
             })

    callback = RuntimeTools.result_contract(contract)

    assert %{status: :ok, value: %{enforced?: true, valid?: true}} =
             callback.(%{"value" => %{"state" => :count}})

    assert %{status: :error, kind: :protocol_error, reason: :invalid_result_contract_request} =
             callback.(%{"value" => %{"state" => :count}, "json_value" => true})
  end

  test "kernel result validation preserves candidate keys until terminal projection" do
    assert {:ok, contract} =
             ValueContract.compile(%{
               "type" => "object",
               "additionalProperties" => false,
               "required" => ["some-key"],
               "properties" => %{
                 "some-key" => %{"type" => "string", "const" => "count"}
               }
             })

    assert {:ok, kernel_component} = Library.component("kernel")
    assert {:ok, bundle} = Kernel.compile_bundle([kernel_component])
    assert {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    assert {:ok, mission} = MissionEnvironment.new([])
    assert {:ok, limits} = Limits.new()
    assert {:ok, sink} = EventSink.start(:normal, limits, run_id: "raw-result-contract")

    assert {:ok, config} =
             RunConfig.new(
               workflow_environment: workflow,
               mission_environment: mission,
               input: %{},
               limits: limits,
               event_sink: sink,
               result_contract: contract,
               result_projection: :json
             )

    source =
      ~S|(let [candidate {"some-key" :count} validation (kernel/validate-result candidate)] (return {"candidate" candidate "validation" validation}))|

    assert {:ok,
            %{
              value: %{
                "candidate" => %{"some-key" => "count"},
                "validation" => %{"enforced?" => true, "valid?" => true}
              }
            }} = Kernel.run(source, config)
  end

  test "private inspection names the JSON projection failure without widening the public error" do
    {:ok, inspection} =
      InspectionSink.start(
        run_id: "keyword-projection-inspection",
        trace_id: "keyword-projection-inspection",
        schema_version: 3
      )

    assert {:error,
            %{
              reason: :invalid_result_projection,
              details: %{result_projection: true}
            }} = run(~S|(return #{1 2})|, :json, inspection_sink: inspection)

    assert {:ok, [record]} = InspectionSink.records(inspection)
    assert record["record_type"] == "execution-error"

    assert record["payload"]["details"] == %{
             "result_projection" => true,
             "projection_error" => "{:invalid_json, [], :unsupported_value}"
           }
  end

  defp run(source, projection, opts \\ []) do
    case build_config(projection, opts) do
      {:ok, config} -> Kernel.run(source, config)
      {:error, _reason} = error -> error
    end
  end

  defp run_with_events(source) do
    {:ok, config} = build_config(:json, [])

    case Kernel.run(source, config) do
      {:ok, result} -> {:ok, result, EventSink.events(config.event_sink)}
      {:error, _reason} = error -> error
    end
  end

  defp build_config(projection, opts) do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    run_id = "keyword-result-#{System.unique_integer([:positive])}"
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)

    RunConfig.new(
      workflow_environment: workflow,
      mission_environment: mission,
      input: %{},
      limits: limits,
      event_sink: sink,
      inspection_sink: Keyword.get(opts, :inspection_sink),
      result_projection: projection
    )
  end
end
