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
    metadata = %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}

    assert MCPProtocol.request(7, "tools/call", %{"name" => "lookup"}, metadata) == %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "method" => "tools/call",
             "params" => %{"name" => "lookup", "_meta" => metadata}
           }

    assert MCPProtocol.notification(
             "notifications/cancelled",
             %{"requestId" => 7},
             metadata
           ) == %{
             "jsonrpc" => "2.0",
             "method" => "notifications/cancelled",
             "params" => %{"requestId" => 7, "_meta" => metadata}
           }
  end

  test "validates bounded upstream tool names for installation and discovery" do
    assert MCPProtocol.valid_tool_name?("vendor.lookup-v2")
    assert MCPProtocol.valid_tool_name?(String.duplicate("x", 128))

    refute MCPProtocol.valid_tool_name?("")
    refute MCPProtocol.valid_tool_name?("bad name")
    refute MCPProtocol.valid_tool_name?("bad\nname")
    refute MCPProtocol.valid_tool_name?(String.duplicate("x", 129))
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

  test "routes stdio responses and accepts protocol notifications" do
    assert {:ok, {:response, 7, %{"result" => %{"ok" => true}} = response}} =
             MCPProtocol.decode_message(~s({"jsonrpc":"2.0","id":7,"result":{"ok":true}}))

    assert response["jsonrpc"] == "2.0"

    assert {:ok, {:notification, notification}} =
             MCPProtocol.decode_message(
               ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}})
             )

    assert notification["method"] == "notifications/progress"

    assert {:ok, {:notification, %{"method" => "notifications/tools/list_changed"}}} =
             MCPProtocol.decode_message(
               ~s({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})
             )

    for body <- [
          ~s({"jsonrpc":"2.0","id":"7","result":{}}),
          ~s({"jsonrpc":"2.0","id":7}),
          ~s({"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}),
          ~s({"jsonrpc":"2.0","id":7,"result":{},"error":{"code":-1,"message":"bad"}}),
          ~s({"jsonrpc":"2.0","method":"tools/list","params":{}}),
          ~s({"jsonrpc":"2.0","method":"notifications/","params":{}}),
          ~s({"jsonrpc":"2.0","method":"notifications/progress","params":[]}),
          ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{},"result":{}}),
          ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{},"error":{}}),
          ~s({"jsonrpc":"2.0","id":7,"id":8,"result":{}})
        ] do
      assert {:error, :mcp_protocol_error} = MCPProtocol.decode_message(body)
    end
  end

  test "rejects inbound JSON above the fixed document depth before decoding" do
    nested = String.duplicate("[", 64) <> "0" <> String.duplicate("]", 64)
    body = ~s({"jsonrpc":"2.0","id":7,"result":#{nested}})

    assert {:error, :mcp_protocol_error} = MCPProtocol.decode_message(body)
  end

  test "rejects decoded inspection exchanges above the fixed document depth" do
    nested = Enum.reduce(1..64, true, fn _level, value -> [value] end)

    request = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{"arguments" => %{"nested" => nested}}
    }

    response = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "result" => %{"nested" => nested}
    }

    refute MCPProtocol.valid_exchange_request?(request, 7)
    refute MCPProtocol.valid_exchange_response?(response, 7)
  end

  test "accepts a complete tools response containing a supported depth-16 schema" do
    instance =
      Enum.reduce(1..15, %{}, fn index, child ->
        %{"level_#{index}" => child}
      end)

    schema =
      Enum.reduce(1..15, %{"type" => "string", "const" => instance}, fn index, child ->
        %{
          "type" => "object",
          "properties" => %{"level_#{index}" => child},
          "additionalProperties" => false
        }
      end)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 7,
        "result" => %{
          "resultType" => "complete",
          "tools" => [%{"name" => "vendor.deep", "inputSchema" => schema}]
        }
      })

    assert {:ok, {:response, 7, %{"result" => %{"tools" => [_tool]}}}} =
             MCPProtocol.decode_message(body)
  end

  test "accepts exactly one valid JSON-RPC outcome" do
    assert {:ok, %{"resultType" => "complete", "tools" => []}} =
             MCPProtocol.outcome(
               %{
                 "result" => %{
                   "resultType" => "complete",
                   "tools" => [],
                   "ttlMs" => 0,
                   "cacheScope" => "private"
                 }
               },
               "tools/list"
             )

    assert {:error, :mcp_protocol_error} =
             MCPProtocol.outcome(
               %{"result" => %{"tools" => [], "ttlMs" => 0, "cacheScope" => "private"}},
               "tools/list"
             )

    assert {:error, :mcp_protocol_error} =
             MCPProtocol.outcome(%{"result" => %{"content" => []}}, "tools/call")

    assert {:error, :mcp_remote_error} =
             MCPProtocol.outcome(
               %{
                 "error" => %{
                   "code" => -32_001,
                   "message" => "not available",
                   "data" => nil
                 }
               },
               "tools/call"
             )

    for response <- [
          %{},
          %{"result" => []},
          %{"result" => %{}, "error" => %{"code" => -1, "message" => "bad"}},
          %{"error" => %{"code" => "-1", "message" => "bad"}},
          %{"error" => %{"code" => -1, "message" => "bad", "unknown" => true}},
          %{"error" => %{"code" => -1, "message" => String.duplicate("x", 4_097)}}
        ] do
      assert {:error, :mcp_protocol_error} = MCPProtocol.outcome(response, "tools/call")
    end

    assert {:error, :mcp_unsupported_result} =
             MCPProtocol.outcome(%{"result" => %{"resultType" => "future"}}, "tools/call")

    for malformed <- [nil, 42, %{}, []] do
      assert {:error, :mcp_protocol_error} =
               MCPProtocol.outcome(
                 %{"result" => %{"resultType" => malformed}},
                 "tools/call"
               )
    end

    assert {:error, :mcp_protocol_error} =
             MCPProtocol.outcome(
               %{"result" => %{"resultType" => "complete", "tools" => []}},
               "tools/list"
             )
  end

  test "classifies only discovery's standard unsupported-profile errors specially" do
    for code <- [-32_601, -32_022] do
      response = %{
        "error" => %{
          "code" => code,
          "message" => "PRIVATE_REMOTE_MESSAGE",
          "data" => %{"secret" => "PRIVATE_REMOTE_DATA"}
        }
      }

      assert {:error, :mcp_protocol_version_unsupported} =
               MCPProtocol.outcome(response, "server/discover")

      assert {:error, :mcp_remote_error} = MCPProtocol.outcome(response, "tools/list")
    end

    assert {:error, :mcp_remote_error} =
             MCPProtocol.outcome(
               %{"error" => %{"code" => -32_603, "message" => "Method not found"}},
               "server/discover"
             )

    assert {:error, :mcp_protocol_error} =
             MCPProtocol.outcome(
               %{
                 "error" => %{
                   "code" => -32_601,
                   "message" => "Method not found",
                   "unexpected" => true
                 }
               },
               "server/discover"
             )
  end

  test "distinguishes a valid unsupported discovery profile from malformed discovery data" do
    valid = %{
      "supportedVersions" => ["2025-11-25"],
      "capabilities" => %{"tools" => %{}}
    }

    assert {:error, :mcp_protocol_version_unsupported} =
             MCPProtocol.discover_result(valid, "2026-07-28")

    for malformed <- [
          Map.put(valid, "capabilities", []),
          put_in(valid, ["capabilities", "tools"], []),
          Map.put(valid, "supportedVersions", ["2025-11-25", 42]),
          Map.put(valid, "supportedVersions", [])
        ] do
      assert {:error, :mcp_protocol_error} =
               MCPProtocol.discover_result(malformed, "2026-07-28")
    end
  end

  test "classifies input-required outcomes by method, structure, and client policy" do
    state_only = %{
      "resultType" => "input_required",
      "requestState" => "eyJwcm9ncmVzcyI6IjUwJSJ9"
    }

    input_requests = %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "github_login" => %{
          "method" => "elicitation/create",
          "params" => %{
            "message" => "Please provide your GitHub username",
            "requestedSchema" => %{
              "type" => "object",
              "properties" => %{"name" => %{"type" => "string"}},
              "required" => ["name"]
            }
          }
        },
        "capital_of_france" => %{
          "method" => "sampling/createMessage",
          "params" => %{
            "messages" => [
              %{
                "role" => "user",
                "content" => %{"type" => "text", "text" => "What is the capital of France?"}
              }
            ],
            "maxTokens" => 100,
            "metadata" => %{"threshold" => 0.5, "fallback" => nil}
          }
        }
      }
    }

    for method <- ["tools/call", "prompts/get", "resources/read"] do
      assert {:error, :mcp_input_required_refused} =
               MCPProtocol.outcome(%{"result" => state_only}, method)

      assert {:error, :mcp_protocol_error} =
               MCPProtocol.outcome(
                 %{"result" => %{"resultType" => "input_required", "inputRequests" => %{}}},
                 method
               )

      assert {:error, :mcp_input_required_refused} =
               MCPProtocol.outcome(
                 %{
                   "result" => %{
                     "resultType" => "input_required",
                     "inputRequests" => %{},
                     "requestState" => "load-shed"
                   }
                 },
                 method
               )

      assert {:error, :mcp_capability_negotiation_error} =
               MCPProtocol.outcome(%{"result" => input_requests}, method)

      assert {:error, :mcp_capability_negotiation_error} =
               MCPProtocol.outcome(
                 %{"result" => Map.put(input_requests, "requestState", "opaque")},
                 method
               )
    end

    assert {:error, :mcp_protocol_error} =
             MCPProtocol.outcome(%{"result" => state_only}, "tools/list")

    assert {:error, :mcp_capability_negotiation_error} =
             MCPProtocol.outcome(
               %{
                 "result" => %{
                   "resultType" => "input_required",
                   "inputRequests" => %{
                     "roots" => %{"method" => "roots/list"}
                   }
                 }
               },
               "tools/call"
             )

    for malformed <- [
          %{"resultType" => "input_required"},
          %{"resultType" => "input_required", "requestState" => 42},
          %{"resultType" => "input_required", "inputRequests" => []},
          %{
            "resultType" => "input_required",
            "inputRequests" => %{},
            "requestState" => nil
          },
          %{
            "resultType" => "input_required",
            "requestState" => "opaque",
            "_meta" => []
          },
          %{
            "resultType" => "input_required",
            "inputRequests" => %{
              "future" => %{"method" => "future/request", "params" => %{}}
            }
          },
          %{
            "resultType" => "input_required",
            "inputRequests" => %{
              "sampling" => %{
                "method" => "sampling/createMessage",
                "params" => %{"messages" => [], "maxTokens" => "many"}
              }
            }
          },
          %{
            "resultType" => "input_required",
            "inputRequests" => %{
              "elicitation" => %{
                "method" => "elicitation/create",
                "params" => %{"message" => "Missing schema"}
              }
            }
          },
          %{
            "resultType" => "input_required",
            "inputRequests" => %{
              "elicitation" => %{
                "method" => "elicitation/create",
                "params" => %{
                  "message" => "Choose values",
                  "requestedSchema" => %{
                    "type" => "object",
                    "properties" => %{
                      "choices" => %{"type" => "array", "items" => %{}}
                    }
                  }
                }
              }
            }
          },
          %{
            "resultType" => "input_required",
            "inputRequests" => %{
              "sampling" => %{
                "method" => "sampling/createMessage",
                "params" => %{
                  "messages" => [
                    %{
                      "role" => "user",
                      "content" => %{
                        "type" => "image",
                        "data" => "not base64!",
                        "mimeType" => "image/png",
                        "annotations" => %{"priority" => "high"}
                      }
                    }
                  ],
                  "maxTokens" => 100
                }
              }
            }
          }
        ] do
      assert {:error, :mcp_protocol_error} =
               MCPProtocol.outcome(%{"result" => malformed}, "tools/call")
    end
  end

  test "accepts standard content annotations and metadata but rejects unknown block fields" do
    content = [
      %{
        "type" => "text",
        "text" => "hello",
        "annotations" => %{
          "audience" => ["assistant"],
          "lastModified" => "2026-07-28T10:00:00+02:00"
        },
        "_meta" => %{"vendor" => true}
      }
    ]

    assert {:ok, %{"text" => ["hello"]}} =
             MCPProtocol.normalize_tool_result(
               %{"content" => content, "isError" => false},
               nil,
               :closed
             )

    for timestamp <- [
          "2026-07-28t10:00:00z",
          "2026-07-28t10:00:00.123z",
          "2026-07-28t10:00:00+02:00"
        ] do
      annotated = [
        %{
          "type" => "text",
          "text" => "hello",
          "annotations" => %{"lastModified" => timestamp}
        }
      ]

      assert {:ok, %{"text" => ["hello"]}} =
               MCPProtocol.normalize_tool_result(
                 %{"content" => annotated, "isError" => false},
                 nil,
                 :closed
               )
    end

    for timestamp <- [
          "yesterday",
          "20260728T100000+0200",
          "2026-07-28T10:00:00+0200",
          "2026-07-28T10:00:00+02"
        ] do
      assert {:error, :mcp_invalid_result} =
               MCPProtocol.normalize_tool_result(
                 %{
                   "content" => [
                     %{
                       "type" => "text",
                       "text" => "hello",
                       "annotations" => %{"lastModified" => timestamp}
                     }
                   ],
                   "isError" => false
                 },
                 nil,
                 :closed
               )
    end

    assert {:error, :mcp_invalid_result} =
             MCPProtocol.normalize_tool_result(
               %{
                 "content" => [
                   %{"type" => "text", "text" => "hello", "unexpected" => true}
                 ],
                 "isError" => false
               },
               nil,
               :closed
             )

    for malformed <- [
          [%{"type" => "text", "text" => "hello", "annotations" => 42}],
          [%{"type" => "text", "text" => "hello", "_meta" => []}],
          [%{"type" => "text", "text" => "hello", "annotations" => %{"audience" => nil}}],
          [%{"type" => "text", "text" => "hello", "annotations" => %{"priority" => nil}}],
          [%{"type" => "text", "text" => "hello", "annotations" => %{"lastModified" => nil}}],
          [
            %{
              "type" => "text",
              "text" => "hello",
              "annotations" => %{"lastModified" => String.duplicate("x", 257)}
            }
          ],
          [
            %{
              "type" => "resource",
              "resource" => %{"uri" => "repo://x", "text" => "hello"},
              "annotations" => "assistant"
            }
          ]
        ] do
      assert {:error, :mcp_invalid_result} =
               MCPProtocol.normalize_tool_result(
                 %{"content" => malformed, "isError" => false},
                 nil,
                 :closed
               )
    end

    assert {:ok,
            %{
              "resources" => [
                %{"uri" => "repo://x", "text" => "hello"}
              ]
            }} =
             MCPProtocol.normalize_tool_result(
               %{
                 "content" => [
                   %{
                     "type" => "resource",
                     "resource" => %{
                       "uri" => "repo://x",
                       "text" => "hello",
                       "_meta" => %{"vendor.example/checksum" => "safe-to-drop"}
                     },
                     "_meta" => %{"vendor.example/display" => true}
                   }
                 ],
                 "isError" => false
               },
               nil,
               :closed
             )
  end

  test "bounded error feedback replaces terminal control characters" do
    assert {:error, {:mcp_domain_error, feedback}} =
             MCPProtocol.normalize_tool_result(
               %{
                 "content" => [
                   %{
                     "type" => "text",
                     "text" => "bad\e[31mred\u009B32mgreen\rforged\tfield\nline"
                   }
                 ],
                 "isError" => true
               },
               nil,
               :bounded
             )

    refute feedback =~ "\e"
    refute feedback =~ "\u009B"
    refute feedback =~ "\r"
    refute feedback =~ "\t"
    refute feedback =~ "\n"
    assert feedback =~ "bad�[31mred"
    assert feedback =~ "green�forged�field�line"
  end

  test "bounded error feedback rejects invalid UTF-8 without raising" do
    assert {:error, :mcp_invalid_result} =
             MCPProtocol.normalize_tool_result(
               %{
                 "content" => [%{"type" => "text", "text" => <<0xFF>>}],
                 "isError" => true
               },
               nil,
               :bounded
             )
  end

  test "reduces catalog pages without interpreting unmapped tool contracts" do
    incomplete_tool = %{
      "name" => "vendor.lookup",
      "inputSchema" => "validated only if selected",
      "unknown" => %{"future" => true}
    }

    state = %{
      tools: %{},
      names: %{},
      seen: %{},
      received_tools: 0,
      received_bytes: 0,
      cache_scope: nil
    }

    assert {:continue, "next",
            %{
              seen: %{"next" => true},
              tools: %{"vendor.lookup" => ^incomplete_tool}
            } = state} =
             MCPProtocol.catalog_page(
               %{
                 "tools" => [incomplete_tool],
                 "nextCursor" => "next",
                 "cacheScope" => "private"
               },
               state,
               10,
               10_000
             )

    valid_tool = %{"name" => "vendor.other", "inputSchema" => @input_schema}

    assert {:done, tools} =
             MCPProtocol.catalog_page(
               %{"tools" => [valid_tool], "cacheScope" => "private"},
               state,
               10,
               10_000
             )

    assert Map.keys(tools) |> Enum.sort() == ["vendor.lookup", "vendor.other"]
  end

  test "rejects duplicate tools, looping cursors, invalid names, and exceeded bounds" do
    tool = %{"name" => "vendor.lookup"}

    state = %{
      tools: %{},
      names: %{},
      seen: %{},
      received_tools: 0,
      received_bytes: 0,
      cache_scope: nil
    }

    cases = [
      {%{"tools" => [tool], "cacheScope" => "private"},
       %{state | tools: %{"vendor.lookup" => tool}, names: %{"vendor.lookup" => true}}, 10,
       10_000},
      {%{"tools" => [tool], "nextCursor" => "seen", "cacheScope" => "private"},
       %{state | seen: %{"seen" => true}}, 10, 10_000},
      {%{"tools" => [%{"name" => "bad name"}], "cacheScope" => "private"}, state, 10, 10_000},
      {%{"tools" => [tool], "cacheScope" => "private"}, state, 0, 10_000},
      {%{"tools" => [tool], "cacheScope" => "private"}, state, 10, 0}
    ]

    for arguments <- cases do
      assert {:error, :mcp_invalid_catalog} =
               apply(MCPProtocol, :catalog_page, Tuple.to_list(arguments))
    end

    assert {:error, :mcp_catalog_exceeded} =
             MCPProtocol.catalog_page(
               %{"tools" => [tool], "cacheScope" => "private"},
               state,
               10,
               1
             )
  end

  test "counts discarded invalid header tools toward catalog ceilings across pages" do
    invalid = %{
      "name" => "vendor.invalid",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "x-mcp-header" => "bad header"}
        }
      }
    }

    state = %{
      tools: %{},
      names: %{},
      seen: %{},
      received_tools: 0,
      received_bytes: 0,
      cache_scope: nil
    }

    assert {:continue, "next", state} =
             MCPProtocol.catalog_page(
               %{"tools" => [invalid], "nextCursor" => "next", "cacheScope" => "private"},
               state,
               1,
               10_000
             )

    assert {:error, :mcp_catalog_exceeded} =
             MCPProtocol.catalog_page(
               %{"tools" => [%{"name" => "vendor.valid"}], "cacheScope" => "private"},
               state,
               1,
               10_000
             )
  end

  test "rejects a valid tool that repeats a discarded tool name on a later page" do
    invalid = %{
      "name" => "vendor.lookup",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "x-mcp-header" => "bad header"}
        }
      }
    }

    state = %{
      tools: %{},
      names: %{},
      seen: %{},
      received_tools: 0,
      received_bytes: 0,
      cache_scope: nil
    }

    assert {:continue, "next", state} =
             MCPProtocol.catalog_page(
               %{"tools" => [invalid], "nextCursor" => "next", "cacheScope" => "private"},
               state,
               10,
               10_000
             )

    assert {:error, :mcp_invalid_catalog} =
             MCPProtocol.catalog_page(
               %{"tools" => [%{"name" => "vendor.lookup"}], "cacheScope" => "private"},
               state,
               10,
               10_000
             )
  end

  test "validates only the selected tool contract and preserves forward-compatible fields" do
    tool = %{
      "name" => "vendor.lookup",
      "description" => "Look up a value",
      "inputSchema" => @input_schema,
      "outputSchema" => @output_schema,
      "execution" => %{"taskSupport" => "removed-and-ignored"},
      "icons" => [%{"src" => "data:image/png;base64,"}],
      "_meta" => %{"vendor" => true}
    }

    assert {:ok,
            %{
              description: "Look up a value",
              input_schema: @input_schema,
              output_schema: @output_schema
            }} = MCPProtocol.selected_tool(tool)

    for invalid <- [
          %{tool | "description" => 42},
          %{tool | "inputSchema" => []},
          %{tool | "outputSchema" => []}
        ] do
      assert {:error, _reason} = MCPProtocol.selected_tool(invalid)
    end
  end

  test "validates and projects x-mcp-header parameters" do
    schema = %{
      "type" => "object",
      "const" => %{"x-mcp-header" => "instance-data"},
      "enum" => [%{"x-mcp-header" => "instance-data"}],
      "x-vendor" => %{"x-mcp-header" => "vendor-data"},
      "properties" => %{
        "region" => %{"type" => "string", "x-mcp-header" => "Region"},
        "nested" => %{
          "type" => "object",
          "properties" => %{
            "attempt" => %{"type" => "integer", "x-mcp-header" => "Attempt"},
            "enabled" => %{"type" => "boolean", "x-mcp-header" => "Enabled"}
          }
        }
      }
    }

    assert {:ok, parameters} = MCPProtocol.header_parameters(schema)

    assert {:ok, headers} =
             MCPProtocol.header_values(parameters, %{
               "region" => " north ",
               "nested" => %{"attempt" => 7, "enabled" => false}
             })

    assert headers == [
             {"mcp-param-Attempt", "7"},
             {"mcp-param-Enabled", "false"},
             {"mcp-param-Region", "=?base64?IG5vcnRoIA==?="}
           ]

    for {value, encoded} <- [
          {7.0, "7"},
          {-0.0, "0"},
          {9_007_199_254_740_991.0, "9007199254740991"}
        ] do
      assert {:ok, [{"mcp-param-Attempt", ^encoded}]} =
               MCPProtocol.header_values(
                 [%{name: "Attempt", path: ["attempt"], type: "integer"}],
                 %{"attempt" => value}
               )
    end

    assert {:error, :mcp_protocol_error} =
             MCPProtocol.header_values(
               [%{name: "Attempt", path: ["attempt"], type: "integer"}],
               %{"attempt" => 9_007_199_254_740_992.0}
             )

    assert MCPProtocol.encode_header("=?base64?literal?=") ==
             "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?="

    assert MCPProtocol.encode_header("") == ""

    assert {:error, :mcp_protocol_error} =
             MCPProtocol.header_values(
               parameters,
               %{"region" => String.duplicate("x", 20_000)}
             )

    too_many_headers =
      Map.put(
        schema,
        "properties",
        Map.new(1..25, fn index ->
          name = "field_#{index}"
          {name, %{"type" => "string", "x-mcp-header" => "Field-#{index}"}}
        end)
      )

    deeply_nested =
      Enum.reduce(1..17, %{"type" => "string"}, fn _index, nested ->
        %{"items" => nested}
      end)

    deeply_nested_annotation =
      Enum.reduce(1..17, "leaf", fn _index, nested ->
        %{"ignored" => nested}
      end)

    for invalid <- [
          too_many_headers,
          deeply_nested,
          Map.put(schema, "const", deeply_nested_annotation),
          put_in(schema, ["properties", "region", "x-mcp-header"], ""),
          put_in(
            schema,
            ["properties", "region", "x-mcp-header"],
            String.duplicate("x", 129)
          ),
          put_in(schema, ["properties", "region", "type"], "number"),
          put_in(
            schema,
            ["properties", "nested", "properties", "attempt", "x-mcp-header"],
            "region"
          ),
          Map.put(schema, "x-mcp-header", "Root"),
          Map.put(schema, "items", %{"x-mcp-header" => "Hidden", "type" => "string"}),
          Map.put(schema, "oneOf", [%{"x-mcp-header" => "Hidden", "type" => "string"}]),
          Map.put(schema, "oneOf", [
            %{
              "properties" => %{
                "hidden" => %{"x-mcp-header" => "Hidden", "type" => "string"}
              }
            }
          ])
        ] do
      assert {:error, :mcp_invalid_tool_schema} = MCPProtocol.header_parameters(invalid)
    end
  end

  test "header scanning follows schema depth and ignores discarded vendor annotations" do
    nested =
      Enum.reduce(1..8, %{"type" => "string"}, fn index, child ->
        %{
          "type" => "object",
          "properties" => %{"level_#{index}" => child}
        }
      end)

    schema = %{
      "type" => "object",
      "properties" => %{"root" => nested},
      "x-vendor-payload" => String.duplicate("x", 70_000)
    }

    assert {:ok, _normalized, _validator} = JSONSchema.compile(schema)
    assert {:ok, []} = MCPProtocol.header_parameters(schema)
  end

  test "header scanning accepts canonical depth-16 scalar schema keywords" do
    leaf = %{
      "type" => "string",
      "const" => "value"
    }

    schema =
      Enum.reduce(1..15, leaf, fn index, child ->
        %{
          "type" => "object",
          "properties" => %{"level_#{index}" => child},
          "additionalProperties" => false
        }
      end)

    assert {:ok, _normalized, _validator} = JSONSchema.compile(schema)
    assert {:ok, []} = MCPProtocol.header_parameters(schema)
  end

  test "normalizes structured, text, and domain-error tool results" do
    {:ok, _normalized, validator} = JSONSchema.compile(@output_schema)

    assert {:ok, %{"value" => 42}} =
             MCPProtocol.normalize_tool_result(
               %{"structuredContent" => %{"value" => 42}, "content" => []},
               validator
             )

    assert {:ok, %{"value" => 42}} =
             MCPProtocol.normalize_tool_result(
               %{
                 "structuredContent" => %{"value" => 42},
                 "content" => [%{"type" => "text", "text" => ~s|{"value":42}|}]
               },
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

    assert {:ok,
            %{
              "text" => ["downloaded"],
              "resources" => [
                %{
                  "uri" => "repo://owner/project/sha/abc/contents/README.md",
                  "mimeType" => "text/plain; charset=utf-8",
                  "text" => "# Project"
                }
              ]
            }} =
             MCPProtocol.normalize_tool_result(
               %{
                 "content" => [
                   %{"type" => "text", "text" => "downloaded"},
                   %{
                     "type" => "resource",
                     "resource" => %{
                       "uri" => "repo://owner/project/sha/abc/contents/README.md",
                       "mimeType" => "text/plain; charset=utf-8",
                       "text" => "# Project"
                     }
                   }
                 ]
               },
               nil
             )

    assert {:error, :mcp_domain_error} =
             MCPProtocol.normalize_tool_result(%{"isError" => true, "content" => []}, validator)

    assert {:error, {:mcp_domain_error, "unknown path�try another path"}} =
             MCPProtocol.normalize_tool_result(
               %{
                 "isError" => true,
                 "content" => [
                   %{"type" => "text", "text" => "unknown path"},
                   %{"type" => "text", "text" => "try another path"}
                 ]
               },
               validator,
               :bounded
             )

    assert {:error, {:mcp_domain_error, bounded_feedback}} =
             MCPProtocol.normalize_tool_result(
               %{
                 "isError" => true,
                 "content" => [
                   %{"type" => "text", "text" => String.duplicate("å", 1_024)}
                 ]
               },
               validator,
               :bounded
             )

    assert byte_size(bounded_feedback) == 1_024
    assert String.valid?(bounded_feedback)

    assert {:error, {:mcp_domain_error, "not exact"}} =
             MCPProtocol.normalize_tool_result(
               %{
                 "isError" => true,
                 "content" => [
                   %{"type" => "text", "text" => "not exact", "annotations" => %{}}
                 ]
               },
               validator,
               :bounded
             )

    for {result, output_validator} <- [
          {%{"structuredContent" => %{"value" => 42}}, validator},
          {%{"isError" => true}, validator},
          {%{"structuredContent" => %{"value" => "wrong"}}, validator},
          {%{"structuredContent" => %{"value" => 42}, "content" => [%{}]}, validator},
          {%{"structuredContent" => %{"value" => 42}, "content" => []}, nil},
          {%{"content" => [%{"type" => "image", "data" => "..."}]}, nil},
          {%{
             "content" => [
               %{"type" => "resource", "resource" => %{"uri" => "repo://x", "blob" => "AA=="}}
             ]
           }, nil},
          {%{"content" => [%{"type" => "text", "text" => "ok", "extra" => true}]}, nil},
          {%{"isError" => "true", "content" => [%{"type" => "text", "text" => "ok"}]}, nil},
          {%{"isError" => nil, "structuredContent" => %{"value" => 42}, "content" => []},
           validator}
        ] do
      assert {:error, :mcp_invalid_result} =
               MCPProtocol.normalize_tool_result(result, output_validator)
    end
  end
end
