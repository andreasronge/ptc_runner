defmodule PtcRunnerMcp.McpResultTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.McpResult

  test "structuredContent wins as JSON value" do
    envelope = %{
      "content" => [%{"type" => "text", "text" => ~S({"ignored":true})}],
      "structuredContent" => %{"answer" => 42}
    }

    assert McpResult.success(envelope) == %{
             ok: true,
             value: %{"answer" => 42},
             value_kind: :json
           }
  end

  test "JSON text is parsed without relying on mimeType" do
    envelope = %{"content" => [%{"type" => "text", "text" => ~S({"items":[1,2]})}]}

    assert McpResult.success(envelope) == %{
             ok: true,
             value: %{"items" => [1, 2]},
             value_kind: :json
           }
  end

  test "JSON null remains a successful JSON nil" do
    envelope = %{"content" => [%{"type" => "text", "text" => "null"}]}

    assert McpResult.success(envelope) == %{ok: true, value: nil, value_kind: :json}
  end

  test "plain text and missing default payload are tagged distinctly" do
    assert McpResult.success(%{"content" => [%{"type" => "text", "text" => "hello"}]}) ==
             %{ok: true, value: "hello", value_kind: :text}

    assert McpResult.success(%{"content" => [%{"type" => "image", "data" => "..."}]}) ==
             %{ok: true, value: nil, value_kind: :none}

    assert McpResult.success(%{"protocol" => "metadata"}) ==
             %{ok: true, value: nil, value_kind: :none}
  end

  test "raw envelope is included only when requested" do
    envelope = %{"content" => [%{"type" => "text", "text" => "hello"}]}

    refute Map.has_key?(McpResult.success(envelope), :raw)
    assert %{raw: ^envelope} = McpResult.success(envelope, raw?: true)
  end

  test "tool error message is bounded on UTF-8 codepoint boundaries" do
    envelope = %{"content" => [%{"type" => "text", "text" => String.duplicate("é", 600)}]}

    message = McpResult.tool_error_message(envelope)

    assert String.length(message) == 501
    assert message == String.duplicate("é", 500) <> "…"
    assert String.valid?(message)
  end

  describe "error/4" do
    test "builds the tagged recoverable failure shape without a raw envelope by default" do
      result = McpResult.error(:cap_exhausted, "budget spent")

      assert result == %{ok: false, reason: :cap_exhausted, message: "budget spent"}
      refute Map.has_key?(result, :raw)
    end

    test "omits raw even when raw? is set but the envelope is nil" do
      result = McpResult.error(:timeout, "took too long", nil, raw?: true)

      assert result == %{ok: false, reason: :timeout, message: "took too long"}
      refute Map.has_key?(result, :raw)
    end

    test "includes the raw envelope only when raw? is set and an envelope is present" do
      envelope = %{"content" => [%{"type" => "text", "text" => "boom"}]}

      assert %{ok: false, reason: :upstream_error, message: "boom", raw: ^envelope} =
               McpResult.error(:upstream_error, "boom", envelope, raw?: true)
    end
  end

  describe "unwrap/1 — non-envelope payloads" do
    test "a bare map (no content/structuredContent) yields no default payload" do
      assert McpResult.unwrap(%{"k" => "v"}) == {nil, :none}
    end

    test "an envelope with non-text content yields no default payload" do
      assert McpResult.unwrap(%{"content" => [%{"type" => "image", "data" => "x"}]}) ==
               {nil, :none}
    end

    test "a bare list is treated as a JSON value" do
      assert McpResult.unwrap([1, 2, 3]) == {[1, 2, 3], :json}
    end

    test "bare booleans are JSON values" do
      assert McpResult.unwrap(true) == {true, :json}
      assert McpResult.unwrap(false) == {false, :json}
    end

    test "bare numbers are JSON values" do
      assert McpResult.unwrap(42) == {42, :json}
      assert McpResult.unwrap(3.5) == {3.5, :json}
    end

    test "a bare non-JSON string is tagged as text" do
      assert McpResult.unwrap("not json {") == {"not json {", :text}
    end

    test "a bare nil is a JSON nil (distinct from an absent payload)" do
      assert McpResult.unwrap(nil) == {nil, :json}
    end

    test "an unhandled term (atom) yields no default payload" do
      assert McpResult.unwrap(:unexpected) == {nil, :none}
    end

    test "explicit structuredContent nil falls through to text/no-default handling" do
      # The `not is_nil(structured)` guard means a nil structuredContent
      # does NOT short-circuit; the text branch wins instead.
      envelope = %{
        "structuredContent" => nil,
        "content" => [%{"type" => "text", "text" => "plain"}]
      }

      assert McpResult.unwrap(envelope) == {"plain", :text}
    end
  end

  describe "tool_error_message/1 — inspect fallback" do
    test "an isError envelope without text content falls back to a bounded inspect" do
      envelope = %{"content" => [%{"type" => "image", "data" => "x"}], "isError" => true}

      message = McpResult.tool_error_message(envelope)

      assert message =~ "upstream isError envelope:"
      assert String.length(message) <= 501
    end

    test "the inspect fallback is itself capped at the 500-char boundary" do
      # A huge non-text envelope: the rendered inspect string is bounded.
      envelope = %{"blob" => String.duplicate("z", 5_000)}

      message = McpResult.tool_error_message(envelope)

      assert message =~ "upstream isError envelope:"
      assert String.length(message) <= 501
      assert String.valid?(message)
    end

    test "first content entry's text wins for the error detail even with a non-text type tag" do
      # `first_error_text/1` reads the first entry's `text` regardless of `type`.
      envelope = %{"content" => [%{"type" => "resource", "text" => "detail here"}]}

      assert McpResult.tool_error_message(envelope) == "detail here"
    end
  end
end
