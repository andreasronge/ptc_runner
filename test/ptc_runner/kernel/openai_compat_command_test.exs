defmodule PtcRunner.Kernel.OpenAICompatCommandTest do
  use ExUnit.Case, async: false
  @moduletag :operator
  @moduletag :tmp_dir

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.TestSupport.LLMSupport
  alias PtcRunner.TestSupport.MCPHTTPFixture

  @schema %{
    "type" => "object",
    "properties" => %{"q" => %{"type" => "boolean"}},
    "required" => ["q"],
    "additionalProperties" => false
  }

  setup do
    snapshot = LLMSupport.snapshot_provider_applications()
    LLMSupport.stop_provider_applications()
    on_exit(fn -> LLMSupport.restore_provider_applications(snapshot) end)
    :ok
  end

  for route <- [:llm, :decision] do
    test "#{route} schema output passes doctor and run with authenticated requests", %{
      tmp_dir: dir
    } do
      project = project(dir, unquote(route), ~s({"q":false}), 200, true)
      assert {:ok, _} = CommandEngine.dispatch(["doctor", project])
      assert {:ok, outcome} = CommandEngine.dispatch(["run", project])
      assert_receive {:wire, wire}
      assert wire.headers["authorization"] == "Bearer fixture-key"
      assert wire.body["max_tokens"] == 512
      format = wire.body["response_format"]
      assert format["type"] == "json_schema"
      assert format["json_schema"]["name"] == "ptc_response"
      assert format["json_schema"]["strict"] == true
      assert format["json_schema"]["schema"]["properties"]["q"] == %{"type" => "boolean"}

      if unquote(route) == :llm do
        assert format["json_schema"]["schema"] == @schema
        assert outcome.envelope["result"]["value"]["structured_output"] == %{"q" => false}
      else
        assert outcome.envelope["result"]["value"]["answers"]["q"]["value"] == false
      end

      assert outcome.envelope["execution"]["usage"]["llm_budget"]["total_tokens"]["charged"] == 12
    end

    for {name, content, status} <- [
          {"invalid schema", ~s({"q":"wrong"}), 200},
          {"truncated", ~s({"q":), 200},
          {"non JSON", "answer", 200},
          {"reasoning", ~s(<think>reason</think>{"q":false}), 200},
          {"array", "[]", 200},
          {"non-string content", %{"q" => false}, 200},
          {"unauthorized", "denied", 401}
        ] do
      test "#{route} rejects #{name} as a provider error", %{tmp_dir: dir} do
        project =
          project(dir, unquote(route), unquote(Macro.escape(content)), unquote(status), true)

        assert {:ok, outcome} = CommandEngine.dispatch(["run", project])
        value = outcome.envelope["result"]["value"]
        assert value["status"] == "error"
        refute Map.has_key?(value, "structured_output")
        refute Map.has_key?(value, "answers")
        assert_receive {:wire, _}
      end
    end

    test "#{route} preserves the existing missing-usage contract", %{tmp_dir: dir} do
      project = project(dir, unquote(route), ~s({"q":false}), 200, false)
      assert {:ok, outcome} = CommandEngine.dispatch(["run", project])
      value = outcome.envelope["result"]["value"]

      if unquote(route) == :llm do
        assert value["structured_output"] == %{"q" => false}
      else
        # The decision answer contract requires observed token counts even when
        # the linked LLM's usage guarantee is optional, as on the ReqLLM route.
        assert value["status"] == "error"
        assert value["kind"] == "invalid_result"
      end

      assert_receive {:wire, _}
    end
  end

  test "cost budget is refused before dispatch", %{tmp_dir: dir} do
    project = project(dir, :llm, ~s({"q":false}), 200, true)
    path = Path.join(dir, "ptc-host.json")
    host = path |> File.read!() |> Jason.decode!()
    host = put_in(host, ["limits", "llm_cost_microusd"], 20_000)

    host =
      put_in(host, ["install", "local", "reservation_tariff"], %{
        "currency" => "USD",
        "id" => "local"
      })

    host = put_in(host, ["install", "local", "usage_guarantees", "cost_currency"], "USD")
    File.write!(path, Jason.encode!(host))
    assert {:error, outcome} = CommandEngine.dispatch(["run", project])
    assert Jason.encode!(outcome.envelope) =~ "model_contract_unsupported"
    refute_received {:wire, _}
  end

  defp project(dir, route, content, status, tokens?) do
    parent = self()

    fixture =
      MCPHTTPFixture.start(fn wire ->
        send(parent, {:wire, wire})
        body = %{"choices" => [%{"message" => %{"content" => content}}]}

        body =
          if tokens?,
            do: Map.put(body, "usage", %{"prompt_tokens" => 10, "completion_tokens" => 2}),
            else: body

        {status, [{"content-type", "application/json"}], Jason.encode!(body)}
      end)

    on_exit(fixture.close)
    File.cp_r!(Path.expand("../../../examples/decision-refund-triage", __DIR__), dir)
    File.rm_rf!(Path.join(dir, ".ptc"))
    manifest_path = Path.join(dir, "ptc.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    library = if route == :llm, do: "llm", else: "decision"
    provider = if route == :llm, do: "local", else: "frozen-decisions"

    manifest =
      put_in(manifest, ["workflow", "components"], [
        %{"library" => library},
        %{"id" => "example.decision", "path" => "workflow.clj", "dependencies" => [library]}
      ])

    manifest = put_in(manifest, ["providers", "workflow"], [%{"name" => provider}])

    input =
      if route == :llm,
        do: %{"messages" => [%{"role" => "user", "content" => "Decide"}], "schema" => @schema},
        else: %{
          "state" => %{},
          "questions" => %{
            "q" => %{"type" => "boolean", "instructions" => "Does the state meet the condition?"}
          }
        }

    manifest = put_in(manifest, ["input", "value"], input)
    File.write!(manifest_path, Jason.encode!(manifest))

    File.write!(
      Path.join(dir, "workflow.clj"),
      "(ns example.decision) (defn run [request] (return (#{library}/request request)))"
    )

    host = %{
      "credentials" => %{"key" => %{"literal" => "fixture-key"}},
      "install" => %{
        "local" => %{
          "source" => "llm",
          "model" => "openai-compat:#{fixture.endpoint}|local-model",
          "credential" => "key",
          "structured_output_mode" => "json_schema",
          "usage_guarantees" => %{"tokens" => tokens?, "cost_currency" => nil},
          "installation_revision" => "local-v1",
          "params" => %{"max_tokens" => 512}
        },
        "frozen-decisions" => %{
          "source" => "decision",
          "backend" => "chat",
          "llm" => "local",
          "installation_revision" => "chat-v1",
          "max_total_tokens_per_call" => 8000,
          "max_cost_per_call" => %{"currency" => "USD", "amount" => "0.01"}
        }
      }
    }

    host = if tokens?, do: Map.put(host, "limits", %{"llm_total_tokens" => 9000}), else: host
    File.write!(Path.join(dir, "ptc-host.json"), Jason.encode!(host))
    Path.join(dir, "ptc-project.json")
  end
end
