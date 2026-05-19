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
end
