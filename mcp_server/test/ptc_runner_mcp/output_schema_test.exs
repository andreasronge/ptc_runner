defmodule PtcRunnerMcp.OutputSchemaTest do
  @moduledoc """
  Phase 3 (§ 10.4) coverage for the `outputSchema` advertised in
  `tools/list`.

  Asserts:

    * The advertised schema is byte-equal to the spec literal.
    * `result` is intentionally NOT in the success branch's
      `required` list (per § 7.4 D2).
    * Concrete R22 / R23 payloads have all fields the schema's
      `required` arrays demand.
  """
  # Calls the real `lisp_eval` tool, which reads process-wide
  # MCP config and the production upstream registry name.
  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]

  alias PtcRunnerMcp.{
    AggregatorConfig,
    CatalogConfig,
    ConcurrencyGate,
    DebugConfig,
    Limits,
    ResponseProfile,
    Tools
  }

  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry

  setup do
    old_debug = DebugConfig.get()
    old_profile = ResponseProfile.current()

    stop_existing_registry(UpstreamRegistry)
    AggregatorConfig.set(AggregatorConfig.defaults())
    CatalogConfig.set(CatalogConfig.defaults())
    Limits.set(Limits.defaults())
    ConcurrencyGate.reset()
    ResponseProfile.set(:debug)
    DebugConfig.set(DebugConfig.defaults())

    on_exit(fn ->
      stop_existing_registry(UpstreamRegistry)
      AggregatorConfig.set(AggregatorConfig.defaults())
      CatalogConfig.set(CatalogConfig.defaults())
      Limits.set(Limits.defaults())
      ConcurrencyGate.reset()
      ResponseProfile.set(old_profile)
      DebugConfig.set(old_debug)
    end)

    :ok
  end

  describe "output_schema/0 shape" do
    test "is byte-equal to the spec literal § 10.4 schema" do
      expected = %{
        "type" => "object",
        "oneOf" => [
          %{
            "type" => "object",
            "required" => ["status", "prints", "feedback", "truncated"],
            "properties" => %{
              "status" => %{"const" => "ok"},
              "result" => %{"type" => "string"},
              "prints" => %{"type" => "array", "items" => %{"type" => "string"}},
              "feedback" => %{"type" => "string"},
              "truncated" => %{"type" => "boolean"},
              "output_truncated" => %{"type" => "boolean"},
              "prints_truncated" => %{"type" => "boolean"},
              "feedback_truncated" => %{"type" => "boolean"},
              "validated" => %{},
              "validated_preview" => %{"type" => "string"},
              "validated_preview_truncated" => %{"type" => "boolean"},
              "validated_bytes" => %{"type" => "integer", "minimum" => 0}
            }
          },
          %{
            "type" => "object",
            "required" => ["status", "reason", "message", "feedback"],
            "properties" => %{
              "status" => %{"const" => "error"},
              "reason" => %{
                "type" => "string",
                "enum" => [
                  "parse_error",
                  "runtime_error",
                  "timeout",
                  "memory_limit",
                  "args_error",
                  "fail",
                  "validation_error",
                  "busy",
                  "cancelled",
                  "unknown_tool",
                  "shutting_down"
                ]
              },
              "message" => %{"type" => "string"},
              "feedback" => %{"type" => "string"},
              "result" => %{"type" => "string"},
              "truncated" => %{"type" => "boolean"},
              "output_truncated" => %{"type" => "boolean"},
              "feedback_truncated" => %{"type" => "boolean"}
            }
          }
        ]
      }

      assert Tools.output_schema() == expected
    end

    test "result is NOT in the success branch's required list (§ 7.4 D2)" do
      [success_branch, _error_branch] = Tools.output_schema()["oneOf"]

      refute "result" in success_branch["required"]
      assert "status" in success_branch["required"]
      assert "prints" in success_branch["required"]
      assert "feedback" in success_branch["required"]
      assert "truncated" in success_branch["required"]
    end

    # Issue #879: each MCP call is one-shot — state never persists across
    # calls — so the response must not surface memory.changed/stored_keys
    # which misled LLMs into thinking they could rely on persistence.
    test "memory is NOT in the success-branch schema (issue #879)" do
      [success_branch, _error_branch] = Tools.output_schema()["oneOf"]

      refute "memory" in success_branch["required"]
      refute Map.has_key?(success_branch["properties"], "memory")
    end

    test "error branch enum lists every reason the server emits" do
      [_success, error] = Tools.output_schema()["oneOf"]
      enum = error["properties"]["reason"]["enum"]

      Enum.each(
        ~w(parse_error runtime_error timeout memory_limit args_error fail
           validation_error busy unknown_tool shutting_down),
        fn reason -> assert reason in enum end
      )
    end
  end

  describe "concrete payloads satisfy the schema's required arrays" do
    test "an R22 success payload has all success-branch required keys" do
      env =
        Tools.call(%{
          "name" => "lisp_eval",
          "arguments" => %{"program" => "(+ 1 2)"}
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      [success_branch, _] = Tools.output_schema()["oneOf"]

      Enum.each(success_branch["required"], fn key ->
        assert Map.has_key?(sc, key), "expected R22 to have key #{inspect(key)}: #{inspect(sc)}"
      end)
    end

    # Issue #879: confirm the actual response payload omits memory, not
    # just that the schema does. Use a defn'd name to make the regression
    # vivid — pre-fix this would have surfaced sum-tree in stored_keys.
    test "an R22 success payload does NOT include the memory field (issue #879)" do
      env =
        Tools.call(%{
          "name" => "lisp_eval",
          "arguments" => %{"program" => "(defn sum-tree [t] (reduce + t)) (sum-tree [1 2 3])"}
        })

      assert env["isError"] == false
      sc = env["structuredContent"]

      refute Map.has_key?(sc, "memory"),
             "MCP one-shot response leaked memory field: #{inspect(sc)}"
    end

    test "an R23 error payload has all error-branch required keys" do
      env =
        Tools.call(%{
          "name" => "lisp_eval",
          "arguments" => %{"program" => "(+ 1"}
        })

      assert env["isError"] == true
      sc = env["structuredContent"]
      [_, error_branch] = Tools.output_schema()["oneOf"]

      Enum.each(error_branch["required"], fn key ->
        assert Map.has_key?(sc, key), "expected R23 to have key #{inspect(key)}: #{inspect(sc)}"
      end)
    end
  end

  describe "tools/list advertisement" do
    test "tool entry includes outputSchema" do
      %{"tools" => [tool]} = Tools.list()
      assert tool["outputSchema"] == Tools.output_schema()
    end

    test "error schema advertises HTTP cancellation envelopes" do
      [_, error_branch] = Tools.output_schema()["oneOf"]
      assert "cancelled" in error_branch["properties"]["reason"]["enum"]
    end
  end
end
