defmodule PtcRunner.Kernel.MCPProtocolTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.MCPProtocol

  @input_schema %{
    "type" => "object",
    "properties" => %{"query" => %{"type" => "string"}},
    "required" => ["query"]
  }
  @output_schema %{
    "type" => "object",
    "properties" => %{"value" => %{"type" => "integer"}},
    "required" => ["value"]
  }

  test "builds JSON-RPC requests and notifications" do
    assert MCPProtocol.request(7, "tools/call", %{"name" => "lookup"}) == %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "method" => "tools/call",
             "params" => %{"name" => "lookup"}
           }

    assert MCPProtocol.notification("notifications/initialized", %{}) == %{
             "jsonrpc" => "2.0",
             "method" => "notifications/initialized",
             "params" => %{}
           }
  end

  test "validates bounded upstream tool names for installation and discovery" do
    assert MCPProtocol.valid_tool_name?("vendor.lookup-v2")
    assert MCPProtocol.valid_tool_name?(String.duplicate("x", 256))

    refute MCPProtocol.valid_tool_name?("")
    refute MCPProtocol.valid_tool_name?("bad name")
    refute MCPProtocol.valid_tool_name?("bad\nname")
    refute MCPProtocol.valid_tool_name?(String.duplicate("x", 257))
    refute MCPProtocol.valid_tool_name?(<<0xFF>>)
    refute MCPProtocol.valid_tool_name?(:lookup)
  end

  test "strictly decodes and correlates JSON-RPC responses" do
    assert {:ok, %{"result" => %{"ok" => true}}} =
             MCPProtocol.decode_response(
               ~s({"jsonrpc":"2.0","id":3,"result":{"ok":true}}),
               3
             )

    for body <- [
          ~s({"jsonrpc":"2.0","id":3,"id":3,"result":{}}),
          ~s({"jsonrpc":"2.0","id":4,"result":{}}),
          ~s({"jsonrpc":"1.0","id":3,"result":{}}),
          ~s({"jsonrpc":"2.0","id":3,"result":{},"bad":NaN}),
          "[]"
        ] do
      assert {:error, :mcp_protocol_error} = MCPProtocol.decode_response(body, 3)
    end
  end

  test "accepts exactly one valid JSON-RPC outcome" do
    assert {:ok, %{"tools" => []}} =
             MCPProtocol.outcome(%{"result" => %{"tools" => []}})

    assert {:error, :mcp_remote_error} =
             MCPProtocol.outcome(%{
               "error" => %{"code" => -32_001, "message" => "not available", "data" => nil}
             })

    for response <- [
          %{},
          %{"result" => []},
          %{"result" => %{}, "error" => %{"code" => -1, "message" => "bad"}},
          %{"error" => %{"code" => "-1", "message" => "bad"}},
          %{"error" => %{"code" => -1, "message" => "bad", "unknown" => true}},
          %{"error" => %{"code" => -1, "message" => String.duplicate("x", 4_097)}}
        ] do
      assert {:error, :mcp_protocol_error} = MCPProtocol.outcome(response)
    end
  end

  test "reduces catalog pages without interpreting unmapped tool contracts" do
    incomplete_tool = %{
      "name" => "vendor.lookup",
      "inputSchema" => "validated only if selected",
      "execution" => %{"taskSupport" => "required"},
      "unknown" => %{"future" => true}
    }

    assert {:continue, "next", %{"next" => true}, %{"vendor.lookup" => ^incomplete_tool}} =
             MCPProtocol.catalog_page(
               %{"tools" => [incomplete_tool], "nextCursor" => "next"},
               %{},
               %{},
               10,
               10_000
             )

    valid_tool = %{"name" => "vendor.other", "inputSchema" => @input_schema}

    assert {:done, tools} =
             MCPProtocol.catalog_page(
               %{"tools" => [valid_tool]},
               %{"vendor.lookup" => incomplete_tool},
               %{"next" => true},
               10,
               10_000
             )

    assert Map.keys(tools) |> Enum.sort() == ["vendor.lookup", "vendor.other"]
  end

  test "rejects duplicate tools, looping cursors, invalid names, and exceeded bounds" do
    tool = %{"name" => "vendor.lookup"}

    cases = [
      {%{"tools" => [tool]}, %{"vendor.lookup" => tool}, %{}, 10, 10_000},
      {%{"tools" => [tool], "nextCursor" => "seen"}, %{}, %{"seen" => true}, 10, 10_000},
      {%{"tools" => [%{"name" => "bad name"}]}, %{}, %{}, 10, 10_000},
      {%{"tools" => [tool]}, %{}, %{}, 0, 10_000},
      {%{"tools" => [tool]}, %{}, %{}, 10, 0}
    ]

    for arguments <- cases do
      assert {:error, :mcp_invalid_catalog} =
               apply(MCPProtocol, :catalog_page, Tuple.to_list(arguments))
    end

    assert {:error, :mcp_catalog_exceeded} =
             MCPProtocol.catalog_page(%{"tools" => [tool]}, %{}, %{}, 10, 1)
  end

  test "validates only the selected tool contract and preserves forward-compatible fields" do
    tool = %{
      "name" => "vendor.lookup",
      "description" => "Look up a value",
      "inputSchema" => @input_schema,
      "outputSchema" => @output_schema,
      "execution" => %{"taskSupport" => "optional"},
      "icons" => [%{"src" => "data:image/png;base64,"}],
      "_meta" => %{"vendor" => true}
    }

    assert {:ok,
            %{
              description: "Look up a value",
              input_schema: @input_schema,
              output_schema: @output_schema
            }} = MCPProtocol.selected_tool(tool)

    assert {:error, :mcp_tool_task_required} =
             MCPProtocol.selected_tool(%{
               tool
               | "execution" => %{"taskSupport" => "required"}
             })

    for invalid <- [
          %{tool | "description" => 42},
          %{tool | "inputSchema" => []},
          %{tool | "outputSchema" => []},
          %{tool | "execution" => %{"taskSupport" => "future"}},
          %{tool | "execution" => []}
        ] do
      assert {:error, _reason} = MCPProtocol.selected_tool(invalid)
    end
  end

  test "normalizes structured, text, and domain-error tool results" do
    {:ok, _normalized, validator} = JSONSchema.compile(@output_schema)

    assert {:ok, %{"value" => 42}} =
             MCPProtocol.normalize_tool_result(
               %{"structuredContent" => %{"value" => 42}, "content" => []},
               validator
             )

    assert {:ok, %{"text" => ["first", "second"]}} =
             MCPProtocol.normalize_tool_result(
               %{
                 "content" => [
                   %{"type" => "text", "text" => "first"},
                   %{"type" => "text", "text" => "second"}
                 ]
               },
               nil
             )

    assert {:error, :mcp_domain_error} =
             MCPProtocol.normalize_tool_result(%{"isError" => true}, validator)

    for {result, output_validator} <- [
          {%{"structuredContent" => %{"value" => "wrong"}}, validator},
          {%{"structuredContent" => %{"value" => 42}, "content" => [%{}]}, validator},
          {%{"structuredContent" => %{"value" => 42}, "content" => []}, nil},
          {%{"content" => [%{"type" => "image", "data" => "..."}]}, nil},
          {%{"content" => [%{"type" => "text", "text" => "ok", "extra" => true}]}, nil}
        ] do
      assert {:error, :mcp_invalid_result} =
               MCPProtocol.normalize_tool_result(result, output_validator)
    end
  end
end
