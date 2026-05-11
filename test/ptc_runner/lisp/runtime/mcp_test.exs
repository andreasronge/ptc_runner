defmodule PtcRunner.Lisp.Runtime.McpTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Runtime.Mcp

  doctest PtcRunner.Lisp.Runtime.Mcp

  describe "text/1 — happy path (§5.1)" do
    test "returns content[0].text from a well-formed MCP envelope" do
      result = %{"content" => [%{"type" => "text", "text" => "hello"}]}
      assert Mcp.text(result) == "hello"
    end

    test "ignores extra content items past index 0 (§5.1 must-not-scan)" do
      result = %{
        "content" => [
          %{"type" => "text", "text" => "first"},
          %{"type" => "text", "text" => "second"}
        ]
      }

      assert Mcp.text(result) == "first"
    end

    test "ignores extra fields on the envelope and the text item" do
      result = %{
        "content" => [
          %{"type" => "text", "text" => "x", "mimeType" => "text/plain", "annotations" => %{}}
        ],
        "isError" => false,
        "structuredContent" => %{"a" => 1}
      }

      assert Mcp.text(result) == "x"
    end
  end

  describe "text/1 — failure modes (§5.1: must not raise; nil on any non-conforming input)" do
    test "returns nil on nil input" do
      assert Mcp.text(nil) == nil
    end

    test "returns nil on the :json-null sentinel (non-map input)" do
      assert Mcp.text(:"json-null") == nil
    end

    test "returns nil on non-map inputs" do
      assert Mcp.text("hello") == nil
      assert Mcp.text(42) == nil
      assert Mcp.text([1, 2, 3]) == nil
      assert Mcp.text(true) == nil
    end

    test "returns nil when content is missing" do
      assert Mcp.text(%{}) == nil
      assert Mcp.text(%{"isError" => false}) == nil
    end

    test "returns nil when content is not a list" do
      assert Mcp.text(%{"content" => "not-a-list"}) == nil
      assert Mcp.text(%{"content" => %{"x" => 1}}) == nil
      assert Mcp.text(%{"content" => nil}) == nil
    end

    test "returns nil when content is empty" do
      assert Mcp.text(%{"content" => []}) == nil
    end

    test "rejects content[0] when type is not exactly \"text\" (image)" do
      result = %{
        "content" => [%{"type" => "image", "text" => "ignored"}]
      }

      assert Mcp.text(result) == nil
    end

    test "rejects content[0] when type is not exactly \"text\" (resource)" do
      result = %{
        "content" => [%{"type" => "resource", "text" => "ignored"}]
      }

      assert Mcp.text(result) == nil
    end

    test "rejects content[0] when type is missing" do
      result = %{"content" => [%{"text" => "ignored"}]}
      assert Mcp.text(result) == nil
    end

    test "rejects content[0] when text field is missing" do
      result = %{"content" => [%{"type" => "text"}]}
      assert Mcp.text(result) == nil
    end

    test "rejects content[0] when text field is not a binary" do
      result = %{"content" => [%{"type" => "text", "text" => 42}]}
      assert Mcp.text(result) == nil

      result_nil = %{"content" => [%{"type" => "text", "text" => nil}]}
      assert Mcp.text(result_nil) == nil
    end

    test "rejects content[0] when first item is not a map" do
      result = %{"content" => ["just-a-string"]}
      assert Mcp.text(result) == nil
    end
  end

  describe "json/1 — structuredContent precedence (§5.2: P1 finding)" do
    test "returns structuredContent verbatim when present, ignoring content[]" do
      # The classic "typed JSON in structuredContent + human summary in text"
      # case. mcp/json MUST return the structured value, not parse the text.
      result = %{
        "structuredContent" => %{"a" => 1, "b" => [2, 3]},
        "content" => [%{"type" => "text", "text" => "Found 1 record."}]
      }

      assert Mcp.json(result) == %{"a" => 1, "b" => [2, 3]}
    end

    test "structuredContent wins even if text is valid JSON of a different shape" do
      result = %{
        "structuredContent" => %{"chosen" => true},
        "content" => [%{"type" => "text", "text" => ~S|{"chosen": false}|}]
      }

      assert Mcp.json(result) == %{"chosen" => true}
    end

    test "structuredContent content mirror is treated as text, not typed JSON" do
      text = "[FILE] README.md\n[DIR] lib"

      result = %{
        "structuredContent" => %{"content" => text},
        "content" => [%{"type" => "text", "text" => text}]
      }

      assert Mcp.json(result) == nil
      assert Mcp.text(result) == text
    end

    test "structuredContent content mirror can still parse real JSON text" do
      text = ~S|{"entries":["README.md","lib"]}|

      result = %{
        "structuredContent" => %{"content" => text},
        "content" => [%{"type" => "text", "text" => text}]
      }

      assert Mcp.json(result) == %{"entries" => ["README.md", "lib"]}
    end

    test "structuredContent content field still wins when it is not a text mirror" do
      result = %{
        "structuredContent" => %{"content" => "typed"},
        "content" => [%{"type" => "text", "text" => "summary"}]
      }

      assert Mcp.json(result) == %{"content" => "typed"}
    end

    test "structuredContent with content plus sibling fields stays intact" do
      result = %{
        "structuredContent" => %{
          "content" => "summary",
          "citations" => ["a.md"]
        },
        "content" => [%{"type" => "text", "text" => "summary"}]
      }

      assert Mcp.json(result) == %{"content" => "summary", "citations" => ["a.md"]}
    end

    test "preserves :json-null sentinel in structuredContent (§6.2 sub-field rule)" do
      # Sub-field :json-null is preserved so programs can distinguish
      # "field present, value JSON null" from "field absent."
      result = %{
        "structuredContent" => :"json-null",
        "content" => [%{"type" => "text", "text" => "null"}]
      }

      assert Mcp.json(result) == :"json-null"
    end

    test "structuredContent: false is also returned verbatim (truthy short-circuit)" do
      # `false` is a valid JSON value and a real structuredContent payload.
      # The §5.2 or-chain must not fall through to the text-parse branch on it.
      result = %{
        "structuredContent" => false,
        "content" => [%{"type" => "text", "text" => "true"}]
      }

      assert Mcp.json(result) == false
    end
  end

  describe "json/1 — text-parse fallback (§5.2 step 2)" do
    test "parses content[0].text when structuredContent is absent" do
      result = %{"content" => [%{"type" => "text", "text" => ~S|{"x":2}|}]}
      assert Mcp.json(result) == %{"x" => 2}
    end

    test "parses content[0].text when structuredContent is nil" do
      result = %{
        "structuredContent" => nil,
        "content" => [%{"type" => "text", "text" => ~S|[1,2,3]|}]
      }

      assert Mcp.json(result) == [1, 2, 3]
    end

    test "returns nil when text is not valid JSON" do
      result = %{"content" => [%{"type" => "text", "text" => "not json"}]}
      assert Mcp.json(result) == nil
    end

    test "returns nil when content[0] is not a text item" do
      result = %{"content" => [%{"type" => "image"}]}
      assert Mcp.json(result) == nil
    end
  end

  describe "json/1 — :json-null propagation table (§6.2)" do
    test "top-level :json-null collapses to nil (Path A)" do
      # The §7.3 top-level rewrite case: result IS :json-null.
      # mcp/json hits the "result is not a map" branch in §5.1, returns nil.
      assert Mcp.json(:"json-null") == nil
    end

    test "sub-field :json-null in structuredContent is preserved (Path B)" do
      # Auto-decode case: outer envelope is a map, structuredContent is :json-null.
      result = %{"structuredContent" => :"json-null"}
      assert Mcp.json(result) == :"json-null"
    end
  end

  describe "json/1 — failure modes (must not raise)" do
    test "returns nil on nil input" do
      assert Mcp.json(nil) == nil
    end

    test "returns nil on non-map input that is not :json-null" do
      assert Mcp.json("plain string") == nil
      assert Mcp.json(42) == nil
      assert Mcp.json([1, 2, 3]) == nil
    end

    test "returns nil on empty map (no structuredContent, no parseable text)" do
      assert Mcp.json(%{}) == nil
    end

    test "returns nil when both paths fail (structuredContent absent, text not parseable)" do
      result = %{"content" => [%{"type" => "text", "text" => "{"}]}
      assert Mcp.json(result) == nil
    end
  end
end
