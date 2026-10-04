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

    test "#{route} keyless installation passes validate, connected doctor and run", %{
      tmp_dir: dir
    } do
      project = project(dir, unquote(route), ~s({"q":false}), 200, true)

      rewrite_host(dir, fn host ->
        host
        |> Map.delete("credentials")
        |> update_in(["install", "local"], &Map.delete(&1, "credential"))
      end)

      assert {:ok, _} =
               CommandEngine.dispatch([
                 "validate",
                 Path.join(dir, "ptc.json"),
                 "--host-config",
                 Path.join(dir, "ptc-host.json")
               ])

      assert {:ok, _} = CommandEngine.dispatch(["doctor", project, "--connect"])
      LLMSupport.stop_provider_applications()
      assert {:ok, outcome} = CommandEngine.dispatch(["run", project])
      value = outcome.envelope["result"]["value"]

      if unquote(route) == :llm do
        assert value["structured_output"] == %{"q" => false}
      else
        assert value["answers"]["q"]["value"] == false
      end

      if unquote(route) == :llm do
        assert_receive {:wire, probe}
        refute Map.has_key?(probe.headers, "authorization")
      end

      assert_receive {:wire, request}
      refute Map.has_key?(request.headers, "authorization")
    end

    test "#{route} configured unset credential fails acquisition", %{tmp_dir: dir} do
      project = project(dir, unquote(route), ~s({"q":false}), 200, true)

      rewrite_host(
        dir,
        &put_in(&1, ["credentials", "key"], %{"env" => "PTC_KEYLESS_TEST_UNSET_KEY"})
      )

      assert System.get_env("PTC_KEYLESS_TEST_UNSET_KEY") == nil

      for command <- [["doctor", project, "--connect"], ["run", project]] do
        LLMSupport.stop_provider_applications()
        assert {:error, outcome} = CommandEngine.dispatch(command)
        assert Jason.encode!(outcome.envelope) =~ "credential_unavailable"
      end

      refute_received {:wire, _}
    end

    for {name, content, status} <- [
          {"invalid schema", ~s({"q":"wrong"}), 200},
          {"truncated", ~s({"q":), 200},
          {"non JSON", "answer", 200},
          {"reasoning", ~s(<think>reason</think>{"q":false}), 200},
          {"array", "[]", 200},
          {"non-string content", %{"q" => false}, 200},
          {"missing content", {:envelope, %{"choices" => [%{"message" => %{}}]}}, 200},
          {"empty choices", {:envelope, %{"choices" => []}}, 200},
          {"missing choices", {:envelope, %{}}, 200},
          {"malformed choices", {:envelope, %{"choices" => "invalid"}}, 200},
          {"malformed message", {:envelope, %{"choices" => [%{"message" => "invalid"}]}}, 200},
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

        if unquote(status) == 200 do
          usage = outcome.envelope["execution"]["usage"]
          assert usage["llm_budget"]["total_tokens"]["charged"] == 12

          assert [%{"usage" => %{"input" => 10, "output" => 2}, "missing_usage_calls" => 0}] =
                   usage["llm_usage"]
        end
      end
    end

    test "#{route} preserves the existing missing-usage contract", %{tmp_dir: dir} do
      project = project(dir, unquote(route), ~s({"q":false}), 200, false)
      assert {:ok, outcome} = CommandEngine.dispatch(["run", project])
      value = outcome.envelope["result"]["value"]

      if unquote(route) == :llm do
        assert value["structured_output"] == %{"q" => false}
      else
        # A decision response must report some valid usage even when the linked
        # LLM's usage guarantee is optional, as on the ReqLLM route.
        assert value["status"] == "error"
        assert value["kind"] == "provider_error"
        assert value["reason"] == "usage_unavailable"
      end

      assert_receive {:wire, _}
    end
  end

  for {name, content} <- [
        {"missing content", {:envelope, %{"choices" => [%{"message" => %{}}]}}},
        {"empty choices", {:envelope, %{"choices" => []}}},
        {"missing choices", {:envelope, %{}}},
        {"malformed choices", {:envelope, %{"choices" => "invalid"}}},
        {"malformed message", {:envelope, %{"choices" => [%{"message" => "invalid"}]}}},
        {"non-string content", %{"q" => false}}
      ] do
    test "ordinary llm rejects #{name} and retains reported usage", %{tmp_dir: dir} do
      project = project(dir, :ordinary, unquote(Macro.escape(content)), 200, true)

      assert {:ok, outcome} = CommandEngine.dispatch(["run", project])

      assert %{"status" => "error", "kind" => "invalid_result"} =
               outcome.envelope["result"]["value"]

      assert_receive {:wire, wire}
      refute Map.has_key?(wire.body, "response_format")
      usage = outcome.envelope["execution"]["usage"]
      assert usage["llm_budget"]["total_tokens"]["charged"] == 12

      assert [%{"usage" => %{"input" => 10, "output" => 2}, "missing_usage_calls" => 0}] =
               usage["llm_usage"]
    end
  end

  test "ordinary llm accepts text without a request schema", %{tmp_dir: dir} do
    project = project(dir, :ordinary, "answer", 200, true)
    assert {:ok, outcome} = CommandEngine.dispatch(["run", project])
    assert outcome.envelope["result"]["value"]["content"] == "answer"
    assert_receive {:wire, wire}
    refute Map.has_key?(wire.body, "response_format")
    assert outcome.envelope["execution"]["usage"]["llm_budget"]["total_tokens"]["charged"] == 12
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

  defp rewrite_host(dir, fun) do
    path = Path.join(dir, "ptc-host.json")
    host = path |> File.read!() |> Jason.decode!() |> fun.()
    File.write!(path, Jason.encode!(host))
  end

  defp project(dir, route, content, status, tokens?) do
    parent = self()

    fixture =
      MCPHTTPFixture.start(fn wire ->
        send(parent, {:wire, wire})

        body =
          case content do
            {:envelope, envelope} -> envelope
            _content -> %{"choices" => [%{"message" => %{"content" => content}}]}
          end

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
    library = if route in [:llm, :ordinary], do: "llm", else: "decision"
    provider = if route in [:llm, :ordinary], do: "local", else: "frozen-decisions"

    manifest =
      put_in(manifest, ["workflow", "components"], [
        %{"library" => library},
        %{"id" => "example.decision", "path" => "workflow.clj", "dependencies" => [library]}
      ])

    manifest = put_in(manifest, ["providers", "workflow"], [%{"name" => provider}])

    input =
      case route do
        :llm ->
          %{"messages" => [%{"role" => "user", "content" => "Decide"}], "schema" => @schema}

        :ordinary ->
          %{"messages" => [%{"role" => "user", "content" => "Decide"}]}

        :decision ->
          %{
            "state" => %{},
            "questions" => %{
              "q" => %{
                "type" => "boolean",
                "instructions" => "Does the state meet the condition?"
              }
            }
          }
      end

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
