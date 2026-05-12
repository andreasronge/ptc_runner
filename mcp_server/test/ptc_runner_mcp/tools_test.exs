defmodule PtcRunnerMcp.ToolsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.PtcToolProtocol
  alias PtcRunnerMcp.Tools

  describe "tool_entry/0" do
    test "advertises exactly one tool named ptc_lisp_execute" do
      %{"tools" => [tool]} = Tools.list()
      assert tool["name"] == "ptc_lisp_execute"
    end

    test "annotations match § 8.1" do
      %{"tools" => [tool]} = Tools.list()
      ann = tool["annotations"]
      assert ann["readOnlyHint"] == true
      assert ann["destructiveHint"] == false
      assert ann["idempotentHint"] == true
      assert ann["openWorldHint"] == false
    end

    test "inputSchema has program required and context/output_schema/signature optional" do
      %{"tools" => [tool]} = Tools.list()
      schema = tool["inputSchema"]

      assert schema["type"] == "object"
      assert schema["required"] == ["program"]
      assert Map.has_key?(schema["properties"], "program")
      assert Map.has_key?(schema["properties"], "context")
      assert Map.has_key?(schema["properties"], "output_schema")
      assert Map.has_key?(schema["properties"], "signature")
    end

    test "outputSchema is advertised verbatim from § 10.4 (Phase 3)" do
      %{"tools" => [tool]} = Tools.list()
      assert tool["outputSchema"] == Tools.output_schema()
    end
  end

  describe "advertised description" do
    test "starts with the :mcp_no_tools profile string byte-for-byte, then \\n\\n, then the card" do
      profile = PtcToolProtocol.tool_description(:mcp_no_tools)
      card = Tools.authoring_card()
      expected = profile <> "\n\n" <> card

      assert Tools.advertised_description() == expected

      %{"tools" => [tool]} = Tools.list()
      assert tool["description"] == expected
    end

    test "contains the protocol-prefix anchor" do
      desc = Tools.advertised_description()
      assert desc =~ "No app tools are available inside the program."
    end

    test "does NOT contain the in-process-with-app-tools anchor" do
      desc = Tools.advertised_description()
      refute desc =~ "Call app tools as `(tool/name ...)`"
    end

    test "contains all five § 8.4 anchors" do
      desc = Tools.advertised_description()
      assert desc =~ "subset of Clojure"
      assert desc =~ "data/"
      assert desc =~ "signature"
      assert desc =~ "(fail"
      assert desc =~ "adjust and retry"
    end
  end

  describe "call/1 — argument validation (§ 9.2)" do
    test "missing program returns args_error" do
      env = Tools.call(%{"name" => "ptc_lisp_execute", "arguments" => %{}})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "program"
    end

    test "missing arguments object treated as empty (program required)" do
      env = Tools.call(%{"name" => "ptc_lisp_execute"})

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "args_error"
    end

    test "non-string program returns args_error" do
      env =
        Tools.call(%{
          "name" => "ptc_lisp_execute",
          "arguments" => %{"program" => 42}
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "args_error"
    end

    test "whitespace-only program returns args_error" do
      env =
        Tools.call(%{
          "name" => "ptc_lisp_execute",
          "arguments" => %{"program" => "   \n\t  "}
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "args_error"
    end

    test "unknown tool name returns the unknown_tool envelope (NOT JSON-RPC -32601)" do
      env = Tools.call(%{"name" => "nope"})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["status"] == "error"
      assert sc["reason"] == "unknown_tool"
      assert sc["message"] =~ "nope"

      [block] = env["content"]
      assert block["type"] == "text"
      assert Jason.decode!(block["text"]) == sc
    end
  end

  describe "call/1 — successful PTC-Lisp execution" do
    test "(+ 1 2) returns isError=false with EDN-rendered result" do
      env =
        Tools.call(%{
          "name" => "ptc_lisp_execute",
          "arguments" => %{"program" => "(+ 1 2)"}
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["status"] == "ok"
      assert sc["result"] == "user=> 3"

      [block] = env["content"]
      assert block["type"] == "text"
      assert Jason.decode!(block["text"]) == sc
    end

    # Plans/ptc-runner-mcp-payload-reduction.md §7 #8: the
    # `:mcp_no_tools` profile has no upstreams → nothing to measure →
    # no `ptc_metrics` (and no `upstream_calls`). This test runs
    # without an `Upstream.Registry`, so `Tools` is in `:mcp_no_tools`
    # mode.
    test "the :mcp_no_tools profile never decorates with ptc_metrics" do
      env =
        Tools.call(%{
          "name" => "ptc_lisp_execute",
          "arguments" => %{"program" => "(+ 1 2)"}
        })

      sc = env["structuredContent"]
      refute Map.has_key?(sc, "ptc_metrics")
      refute Map.has_key?(sc, "upstream_calls")
    end
  end
end
