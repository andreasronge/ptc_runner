defmodule PtcRunner.Upstream.Transport.McpResultTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Upstream.Transport.McpResult

  # McpResult.normalize/1 collapses an MCP tools/call envelope into a
  # PtcRunner.Upstream.Result tuple. Both MCP transports share it, so its
  # branch choices (isError, structuredContent, text decode, no-text) are the
  # data-integrity dispatch every upstream tool result flows through.

  describe "normalize/1 success branches" do
    test "structuredContent passes through as the value" do
      result = %{"structuredContent" => %{"a" => 1}}
      assert McpResult.normalize(result) == {:ok, %{"a" => 1}}
    end

    test "structuredContent takes precedence over text content" do
      result = %{
        "structuredContent" => %{"from" => "structured"},
        "content" => [%{"type" => "text", "text" => ~s({"from":"text"})}]
      }

      assert McpResult.normalize(result) == {:ok, %{"from" => "structured"}}
    end

    test "JSON text content is decoded" do
      result = %{"content" => [%{"type" => "text", "text" => ~s({"n":2})}]}
      assert McpResult.normalize(result) == {:ok, %{"n" => 2}}
    end

    test "non-JSON text content passes through as a raw string" do
      result = %{"content" => [%{"type" => "text", "text" => "just words"}]}
      assert McpResult.normalize(result) == {:ok, "just words"}
    end

    test "image-only content (no text block) normalizes to nil" do
      result = %{
        "content" => [%{"type" => "image", "data" => "base64", "mimeType" => "image/png"}]
      }

      assert McpResult.normalize(result) == {:ok, nil}
    end

    test "empty content list normalizes to nil" do
      assert McpResult.normalize(%{"content" => []}) == {:ok, nil}
    end

    test "missing content key normalizes to nil" do
      assert McpResult.normalize(%{}) == {:ok, nil}
    end

    test "a text block after a non-text block is still returned" do
      result = %{
        "content" => [
          %{"type" => "image", "data" => "b64"},
          %{"type" => "text", "text" => "recovered"}
        ]
      }

      assert McpResult.normalize(result) == {:ok, "recovered"}
    end
  end

  describe "normalize/1 error branch" do
    test "isError surfaces a text block that follows a non-text block" do
      result = %{
        "isError" => true,
        "content" => [
          %{"type" => "image", "data" => "b64"},
          %{"type" => "text", "text" => "boom"}
        ]
      }

      assert McpResult.normalize(result) == {:error, :tool_error, "boom"}
    end

    test "isError with a text block returns the text" do
      result = %{"isError" => true, "content" => [%{"type" => "text", "text" => "boom"}]}
      assert McpResult.normalize(result) == {:error, :tool_error, "boom"}
    end

    test "isError without text falls back to an inspected envelope" do
      result = %{"isError" => true, "content" => [%{"type" => "image", "data" => "b64"}]}

      assert {:error, :tool_error, text} = McpResult.normalize(result)
      assert text =~ "isError"
      assert text =~ "image"
    end

    test "structuredContent is ignored when isError is true" do
      result = %{
        "isError" => true,
        "structuredContent" => %{"ignored" => true},
        "content" => [%{"type" => "text", "text" => "the error"}]
      }

      assert McpResult.normalize(result) == {:error, :tool_error, "the error"}
    end
  end
end
