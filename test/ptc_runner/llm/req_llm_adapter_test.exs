defmodule PtcRunner.LLM.ReqLLMAdapterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.LLM.ReqLLMAdapter

  describe "generate_object/4" do
    test "returns structured_output_not_supported for ollama" do
      assert {:error, :structured_output_not_supported} =
               ReqLLMAdapter.generate_object("ollama:model", [], %{})
    end

    test "returns structured_output_not_supported for openai-compat" do
      assert {:error, :structured_output_not_supported} =
               ReqLLMAdapter.generate_object("openai-compat:http://localhost|model", [], %{})
    end
  end

  describe "generate_object!/4" do
    test "raises for ollama" do
      assert_raise RuntimeError, ~r/structured_output_not_supported/, fn ->
        ReqLLMAdapter.generate_object!("ollama:model", [], %{})
      end
    end

    test "raises for openai-compat" do
      assert_raise RuntimeError, ~r/structured_output_not_supported/, fn ->
        ReqLLMAdapter.generate_object!("openai-compat:http://localhost|model", [], %{})
      end
    end
  end

  describe "generate_with_tools/4" do
    test "returns tool_calling_not_supported for ollama" do
      assert {:error, :tool_calling_not_supported} =
               ReqLLMAdapter.generate_with_tools("ollama:model", [], [])
    end

    test "returns tool_calling_not_supported for openai-compat" do
      assert {:error, :tool_calling_not_supported} =
               ReqLLMAdapter.generate_with_tools("openai-compat:http://localhost|model", [], [])
    end
  end

  describe "call/2" do
    test "routes schema mode to generate_object for ollama" do
      req = %{
        system: "You are helpful",
        messages: [%{role: :user, content: "test"}],
        schema: %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}
      }

      assert {:error, :structured_output_not_supported} = ReqLLMAdapter.call("ollama:test", req)
    end

    test "routes text mode to generate_text" do
      req = %{
        system: "You are helpful",
        messages: [%{role: :user, content: "test"}],
        cache: false
      }

      # Will fail with connection error for ollama, confirming routing to generate_text
      assert {:error, _} = ReqLLMAdapter.call("ollama:test", req)
    end
  end

  describe "available?/1" do
    test "returns boolean for cloud providers" do
      assert is_boolean(ReqLLMAdapter.available?("openrouter:anthropic/claude-haiku-4.5"))
    end
  end

  describe "requires_api_key?/1" do
    test "returns false for ollama" do
      refute ReqLLMAdapter.requires_api_key?("ollama:model")
    end

    test "returns false for openai-compat" do
      refute ReqLLMAdapter.requires_api_key?("openai-compat:http://localhost|model")
    end

    test "returns true for cloud providers" do
      assert ReqLLMAdapter.requires_api_key?("openrouter:model")
    end
  end

  describe "embed/3" do
    test "embed! raises on connection error" do
      assert_raise RuntimeError, ~r/Embedding error/, fn ->
        ReqLLMAdapter.embed!("ollama:nomic-embed-text", "hello",
          ollama_base_url: "http://localhost:1"
        )
      end
    end
  end

  describe "stream/2" do
    test "returns error for ollama" do
      assert {:error, :streaming_not_supported} =
               ReqLLMAdapter.stream("ollama:model", %{system: "test", messages: []})
    end

    test "returns error for openai-compat" do
      assert {:error, :streaming_not_supported} =
               ReqLLMAdapter.stream("openai-compat:http://localhost|model", %{
                 system: "test",
                 messages: []
               })
    end
  end
end
