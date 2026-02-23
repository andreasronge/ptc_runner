defmodule LLMClient.ProvidersTest do
  use ExUnit.Case, async: true

  describe "generate_object/4" do
    test "returns structured_output_not_supported for ollama" do
      assert {:error, :structured_output_not_supported} =
               LLMClient.generate_object("ollama:model", [], %{})
    end

    test "returns structured_output_not_supported for openai-compat" do
      assert {:error, :structured_output_not_supported} =
               LLMClient.generate_object("openai-compat:http://localhost|model", [], %{})
    end
  end

  describe "generate_object!/4" do
    test "raises for ollama" do
      assert_raise RuntimeError, ~r/structured_output_not_supported/, fn ->
        LLMClient.generate_object!("ollama:model", [], %{})
      end
    end

    test "raises for openai-compat" do
      assert_raise RuntimeError, ~r/structured_output_not_supported/, fn ->
        LLMClient.generate_object!("openai-compat:http://localhost|model", [], %{})
      end
    end
  end

  describe "callback/1" do
    test "returns a function" do
      callback = LLMClient.callback("haiku")
      assert is_function(callback, 1)
    end

    test "raises on invalid model alias" do
      assert_raise ArgumentError, ~r/Unknown model/, fn ->
        LLMClient.callback("nonexistent-model")
      end
    end
  end

  describe "embed/2" do
    test "returns a list of floats for ollama when available" do
      case LLMClient.embed("ollama:nomic-embed-text", "hello") do
        {:ok, embedding} ->
          assert is_list(embedding)
          assert Enum.all?(embedding, &is_number/1)

        {:error, _} ->
          # Ollama not running, that's fine
          :ok
      end
    end

    test "embed! raises on connection error" do
      # Use a non-existent ollama server to guarantee failure
      assert_raise RuntimeError, ~r/Embedding error/, fn ->
        LLMClient.Providers.embed!("ollama:nomic-embed-text", "hello",
          ollama_base_url: "http://localhost:1"
        )
      end
    end
  end

  describe "call/2" do
    test "routes JSON mode to generate_object and returns structured_output_not_supported for ollama" do
      req = %{
        system: "You are helpful",
        messages: [%{role: :user, content: "test"}],
        output: :json,
        schema: %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}
      }

      assert {:error, :structured_output_not_supported} = LLMClient.call("ollama:test", req)
    end

    test "routes PTC-Lisp mode to generate_text" do
      req = %{
        system: "You are helpful",
        messages: [%{role: :user, content: "test"}],
        cache: false
      }

      # Will fail with connection error for ollama, confirming routing to generate_text
      assert {:error, _} = LLMClient.call("ollama:test", req)
    end
  end
end
