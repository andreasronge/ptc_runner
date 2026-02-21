defmodule PtcRunner.SubAgent.LLMResolverTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.LLMResolver

  doctest LLMResolver

  describe "resolve/3 with function LLM" do
    test "normalizes plain string response" do
      llm = fn _input -> {:ok, "Hello world"} end

      assert {:ok, %{content: "Hello world", tokens: nil}} =
               LLMResolver.resolve(llm, %{messages: []}, %{})
    end

    test "normalizes map response with content only" do
      llm = fn _input -> {:ok, %{content: "Hello world"}} end

      assert {:ok, %{content: "Hello world", tokens: nil}} =
               LLMResolver.resolve(llm, %{messages: []}, %{})
    end

    test "preserves tokens from map response" do
      llm = fn _input ->
        {:ok, %{content: "Hello world", tokens: %{input: 10, output: 5}}}
      end

      assert {:ok, %{content: "Hello world", tokens: %{input: 10, output: 5}}} =
               LLMResolver.resolve(llm, %{messages: []}, %{})
    end

    test "handles partial token info" do
      llm = fn _input ->
        {:ok, %{content: "Hello world", tokens: %{input: 10}}}
      end

      assert {:ok, %{content: "Hello world", tokens: %{input: 10}}} =
               LLMResolver.resolve(llm, %{messages: []}, %{})
    end

    test "passes through error results" do
      llm = fn _input -> {:error, :timeout} end

      assert {:error, :timeout} = LLMResolver.resolve(llm, %{messages: []}, %{})
    end
  end

  describe "resolve/3 with registry atom" do
    test "normalizes plain string response from registry" do
      registry = %{
        haiku: fn _input -> {:ok, "Registry response"} end
      }

      assert {:ok, %{content: "Registry response", tokens: nil}} =
               LLMResolver.resolve(:haiku, %{messages: []}, registry)
    end

    test "preserves tokens from registry response" do
      registry = %{
        haiku: fn _input ->
          {:ok, %{content: "Registry response", tokens: %{input: 100, output: 50}}}
        end
      }

      assert {:ok, %{content: "Registry response", tokens: %{input: 100, output: 50}}} =
               LLMResolver.resolve(:haiku, %{messages: []}, registry)
    end

    test "returns error for unknown atom" do
      registry = %{haiku: fn _input -> {:ok, "response"} end}

      assert {:error, {:llm_not_found, _msg}} =
               LLMResolver.resolve(:unknown, %{messages: []}, registry)
    end

    test "returns error for empty registry" do
      assert {:error, {:llm_registry_required, _msg}} =
               LLMResolver.resolve(:haiku, %{messages: []}, %{})
    end
  end

  describe "normalize_response/1" do
    test "normalizes string to map with nil tokens" do
      assert LLMResolver.normalize_response("hello") == %{content: "hello", tokens: nil}
    end

    test "normalizes map without tokens" do
      assert LLMResolver.normalize_response(%{content: "hello"}) ==
               %{content: "hello", tokens: nil}
    end

    test "normalizes map with tokens" do
      assert LLMResolver.normalize_response(%{content: "hello", tokens: %{input: 5, output: 3}}) ==
               %{content: "hello", tokens: %{input: 5, output: 3}}
    end

    test "ignores extra keys in response map" do
      response = %{content: "hello", tokens: %{input: 5}, extra: "ignored"}
      assert LLMResolver.normalize_response(response) == %{content: "hello", tokens: %{input: 5}}
    end

    test "normalizes tool_calls response" do
      response = %{
        tool_calls: [%{id: "tc_1", name: "search", args: %{"q" => "foo"}}],
        content: nil,
        tokens: %{input: 10, output: 5}
      }

      assert LLMResolver.normalize_response(response) == %{
               tool_calls: [%{id: "tc_1", name: "search", args: %{"q" => "foo"}}],
               content: nil,
               tokens: %{input: 10, output: 5}
             }
    end

    test "handles map with nil content (catch-all clause)" do
      response = %{some_field: "value"}
      assert LLMResolver.normalize_response(response) == %{content: nil, tokens: nil}
    end

    test "handles empty map" do
      assert LLMResolver.normalize_response(%{}) == %{content: nil, tokens: nil}
    end
  end
end
