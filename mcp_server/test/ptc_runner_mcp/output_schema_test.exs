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
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Tools

  describe "output_schema/0 shape" do
    test "is byte-equal to the spec literal § 10.4 schema" do
      expected = %{
        "type" => "object",
        "oneOf" => [
          %{
            "type" => "object",
            "required" => ["status", "prints", "feedback", "memory", "truncated"],
            "properties" => %{
              "status" => %{"const" => "ok"},
              "result" => %{"type" => "string"},
              "prints" => %{"type" => "array", "items" => %{"type" => "string"}},
              "feedback" => %{"type" => "string"},
              "memory" => %{
                "type" => "object",
                "required" => ["changed", "stored_keys", "truncated"],
                "properties" => %{
                  "changed" => %{
                    "type" => "object",
                    "additionalProperties" => %{"type" => "string"}
                  },
                  "stored_keys" => %{"type" => "array", "items" => %{"type" => "string"}},
                  "truncated" => %{"type" => "boolean"}
                }
              },
              "truncated" => %{"type" => "boolean"},
              "validated" => %{}
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
                  "unknown_tool",
                  "shutting_down"
                ]
              },
              "message" => %{"type" => "string"},
              "feedback" => %{"type" => "string"},
              "result" => %{"type" => "string"}
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
      assert "memory" in success_branch["required"]
      assert "truncated" in success_branch["required"]
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
          "name" => "ptc_lisp_execute",
          "arguments" => %{"program" => "(+ 1 2)"}
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      [success_branch, _] = Tools.output_schema()["oneOf"]

      Enum.each(success_branch["required"], fn key ->
        assert Map.has_key?(sc, key), "expected R22 to have key #{inspect(key)}: #{inspect(sc)}"
      end)
    end

    test "an R23 error payload has all error-branch required keys" do
      env =
        Tools.call(%{
          "name" => "ptc_lisp_execute",
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
  end
end
