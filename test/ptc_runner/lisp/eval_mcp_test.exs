defmodule PtcRunner.Lisp.EvalMcpTest do
  @moduledoc """
  End-to-end PTC-Lisp tests for `mcp/text` and `mcp/json`.

  Covers the §1 motivating use case: replacing the `re-find` regex
  workaround with `(mcp/json (tool/mcp-call ...))` for upstreams that
  return JSON-as-text in `content[0].text`. Also exercises the §5.2
  `structuredContent` precedence and the §6.2 `:json-null` propagation
  table (top-level vs sub-field).
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  # Stub a tool literally named `mcp-call`. The analyzer's `(tool/...)`
  # path routes (tool/mcp-call ...) through tool_exec by tool name, so
  # this is the same shape an aggregator-side mcp-call would have.
  defp stub_tool(impl) when is_function(impl, 1) do
    %{"mcp-call" => impl}
  end

  describe "(mcp/text ...) over a stub tool/mcp-call" do
    test "extracts content[0].text from a well-formed envelope" do
      tools =
        stub_tool(fn _args ->
          %{"content" => [%{"type" => "text", "text" => "hello"}]}
        end)

      source = ~S|(mcp/text (tool/mcp-call {:server "fake" :tool "echo" :args {}}))|
      assert {:ok, %{return: "hello"}} = Lisp.run(source, tools: tools)
    end

    test "returns nil when content[0] is not a text item" do
      tools =
        stub_tool(fn _args ->
          %{"content" => [%{"type" => "image", "data" => "..."}]}
        end)

      source = ~S|(mcp/text (tool/mcp-call {:server "fake" :tool "img" :args {}}))|
      assert {:ok, %{return: nil}} = Lisp.run(source, tools: tools)
    end
  end

  describe "(mcp/json ...) over a stub tool/mcp-call (§1 motivating case)" do
    test "parses JSON-as-text in content[0].text — replaces the re-find workaround" do
      # Generic graph-shaped JSON (the original motivating shape was a
      # memory-graph upstream returning JSON-as-text; the helper makes the
      # regex split workaround unnecessary).
      payload =
        Jason.encode!(%{
          "entities" => [%{"name" => "n1"}, %{"name" => "n2"}],
          "relations" => [%{"from" => "n1", "to" => "n2"}]
        })

      tools =
        stub_tool(fn _args ->
          %{"content" => [%{"type" => "text", "text" => payload}]}
        end)

      source = ~S"""
      (let [g (mcp/json (tool/mcp-call {:server "graph" :tool "read" :args {}}))]
        {:entity-count (count (get g "entities"))
         :relation-count (count (get g "relations"))})
      """

      assert {:ok, %{return: %{"entity-count": 2, "relation-count": 1}}} =
               Lisp.run(source, tools: tools)
    end

    test "structuredContent wins over content[].text (§5.2 precedence)" do
      # The aggregator's auto-decode (Phase C) populates structuredContent;
      # mcp/json must consult it first, NOT re-parse content[0].text.
      tools =
        stub_tool(fn _args ->
          %{
            "structuredContent" => %{"x" => 99},
            "content" => [%{"type" => "text", "text" => ~S|{"x":1}|}]
          }
        end)

      source = ~S|(mcp/json (tool/mcp-call {:server "s" :tool "t" :args {}}))|
      assert {:ok, %{return: %{"x" => 99}}} = Lisp.run(source, tools: tools)
    end

    test "returns nil when both structuredContent and text-parse fail" do
      tools =
        stub_tool(fn _args ->
          %{"content" => [%{"type" => "text", "text" => "not-json"}]}
        end)

      source = ~S|(mcp/json (tool/mcp-call {:server "s" :tool "t" :args {}}))|
      assert {:ok, %{return: nil}} = Lisp.run(source, tools: tools)
    end
  end

  describe ":json-null propagation table (§6.2)" do
    test "top-level :json-null collapses to nil through mcp/json (Path A)" do
      # Programs in the base library can't generate :json-null directly via
      # tool/mcp-call (the §7.3 rewrite is aggregator-side), but mcp/json
      # must still handle the keyword if it shows up. Use a stub that
      # returns :json-null directly to exercise Path A.
      tools = stub_tool(fn _args -> :"json-null" end)
      source = ~S|(mcp/json (tool/mcp-call {:server "s" :tool "t" :args {}}))|
      assert {:ok, %{return: nil}} = Lisp.run(source, tools: tools)
    end

    test "sub-field :json-null in structuredContent is preserved (Path B)" do
      tools = stub_tool(fn _args -> %{"structuredContent" => :"json-null"} end)
      source = ~S|(mcp/json (tool/mcp-call {:server "s" :tool "t" :args {}}))|
      assert {:ok, %{return: :"json-null"}} = Lisp.run(source, tools: tools)
    end
  end

  describe "analyzer suggestions for unknown mcp/ members" do
    test "mcp/foo lists the available mcp/* members" do
      source = ~S|(mcp/foo {})|
      assert {:error, %{fail: %{message: msg}}} = Lisp.run(source)
      assert msg =~ "mcp/foo is not available"
      assert msg =~ "mcp/text"
      assert msg =~ "mcp/json"
    end
  end
end
