defmodule PtcRunner.LLM.ReqLLMAdapterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.LLM.ReqLLMAdapter
  alias ReqLLM.Message
  alias ReqLLM.ToolCall

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

  # --- Pure transformers (network-free): prompt-cache activation & token/cost accounting ---

  describe "apply_caching/3 — Anthropic direct" do
    test "turns on anthropic_prompt_cache with 5m ttl and leaves messages unchanged" do
      messages = [%{role: :user, content: "hi"}]

      assert {^messages, opts} =
               ReqLLMAdapter.apply_caching("anthropic:claude-3-5-sonnet", messages, true)

      assert opts == [
               provider_options: [
                 anthropic_prompt_cache: true,
                 anthropic_prompt_cache_ttl: "5m"
               ]
             ]
    end
  end

  describe "apply_caching/3 — OpenRouter Anthropic" do
    test "pins the Anthropic provider and stamps cache_control on the last system message" do
      messages = [
        %{role: :system, content: "sys"},
        %{role: :user, content: "hi"}
      ]

      assert {cached_messages, opts} =
               ReqLLMAdapter.apply_caching(
                 "openrouter:anthropic/claude-3.5-sonnet",
                 messages,
                 true
               )

      # Pins provider routing to Anthropic with no fallbacks (so caching is honored).
      assert opts == [
               openrouter_provider: %{order: ["Anthropic"], allow_fallbacks: false}
             ]

      # Messages are rewritten to %Message{} structs; the (last) system message
      # carries the ephemeral cache_control marker.
      [system_msg, user_msg] = cached_messages
      assert %Message{role: :system, content: [system_part]} = system_msg
      assert system_part.text == "sys"
      assert system_part.metadata == %{cache_control: %{type: "ephemeral"}}

      assert %Message{role: :user, content: [user_part]} = user_msg
      assert user_part.text == "hi"
      assert user_part.metadata == %{}
    end

    test "matches via the 'claude' substring even without 'anthropic'" do
      messages = [%{role: :user, content: "hi"}]

      assert {_messages, opts} =
               ReqLLMAdapter.apply_caching("openrouter:some/claude-model", messages, true)

      assert Keyword.has_key?(opts, :openrouter_provider)
    end
  end

  describe "apply_caching/3 — Bedrock" do
    test "enables anthropic_prompt_cache for bedrock models, messages unchanged" do
      messages = [%{role: :user, content: "hi"}]

      assert {^messages, opts} =
               ReqLLMAdapter.apply_caching("amazon_bedrock:anthropic.claude-x", messages, true)

      assert opts == [
               provider_options: [
                 anthropic_prompt_cache: true,
                 anthropic_prompt_cache_ttl: "5m"
               ]
             ]
    end
  end

  describe "apply_caching/3 — non-cacheable / disabled" do
    test "non-cacheable provider returns empty opts and unchanged messages" do
      messages = [%{role: :user, content: "hi"}]

      assert {^messages, []} =
               ReqLLMAdapter.apply_caching("openai:gpt-4o", messages, true)
    end

    test "cache disabled returns empty opts and unchanged messages even for anthropic" do
      messages = [%{role: :system, content: "sys"}, %{role: :user, content: "hi"}]

      assert {^messages, []} =
               ReqLLMAdapter.apply_caching("anthropic:claude-3-5-sonnet", messages, false)
    end
  end

  describe "maybe_resolve_inference_profile/1" do
    test "passes through non-bedrock model strings unchanged" do
      assert ReqLLMAdapter.maybe_resolve_inference_profile("openrouter:anthropic/claude") ==
               "openrouter:anthropic/claude"

      assert ReqLLMAdapter.maybe_resolve_inference_profile("anthropic:claude-3-5-sonnet") ==
               "anthropic:claude-3-5-sonnet"
    end

    test "passes through bedrock models with no inference-prefix and no required family" do
      # Not "us./eu./ap./ca./global." and not the "amazon." family -> the
      # passthrough `true` branch returns the full string unchanged (no registry hit).
      full = "amazon_bedrock:anthropic.claude-3-haiku"
      assert ReqLLMAdapter.maybe_resolve_inference_profile(full) == full
    end
  end

  describe "build_tokens_from_req_llm_response/2" do
    test "reads atom-keyed usage including cache read/creation and cost" do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        cache_read_input_tokens: 20,
        cache_creation_input_tokens: 10,
        total_cost: 0.5
      }

      assert ReqLLMAdapter.build_tokens_from_req_llm_response(usage, %{}) == %{
               input: 100,
               output: 50,
               cache_read: 20,
               cache_creation: 10,
               total_cost: 0.5
             }
    end

    test "reads string-keyed usage and falls back to cached_tokens for cache reads" do
      usage = %{"input_tokens" => 7, "output_tokens" => 3, "cached_tokens" => 2}

      assert ReqLLMAdapter.build_tokens_from_req_llm_response(usage, %{}) == %{
               input: 7,
               output: 3,
               cache_read: 2,
               cache_creation: 0,
               total_cost: 0.0
             }
    end

    test "derives cache_creation from provider_meta cache_write_tokens when usage omits it" do
      usage = %{input_tokens: 1}
      meta = %{"usage" => %{"prompt_tokens_details" => %{"cache_write_tokens" => 42}}}

      assert ReqLLMAdapter.build_tokens_from_req_llm_response(usage, meta) == %{
               input: 1,
               output: 0,
               cache_read: 0,
               cache_creation: 42,
               total_cost: 0.0
             }
    end

    test "defaults all fields to zero for empty usage and meta" do
      assert ReqLLMAdapter.build_tokens_from_req_llm_response(%{}, %{}) == %{
               input: 0,
               output: 0,
               cache_read: 0,
               cache_creation: 0,
               total_cost: 0.0
             }
    end
  end

  describe "normalize_tool_calls/1" do
    test "decodes well-formed JSON arguments into a map" do
      tc = ToolCall.new("call_1", "get_weather", ~s({"city":"Paris"}))

      assert [%{id: "call_1", name: "get_weather", args: %{"city" => "Paris"}} = entry] =
               ReqLLMAdapter.normalize_tool_calls([tc])

      refute Map.has_key?(entry, :args_error)
    end

    test "records args_error and empty args for invalid-JSON arguments" do
      tc = ToolCall.new("call_2", "broken", "{not json")

      assert [entry] = ReqLLMAdapter.normalize_tool_calls([tc])
      assert entry.id == "call_2"
      assert entry.name == "broken"
      assert entry.args == %{}
      assert entry.args_error == "Invalid JSON arguments: {not json"
    end

    test "treats nil arguments as empty object (no error)" do
      tc = %ToolCall{id: "call_3", type: "function", function: %{name: "n", arguments: nil}}

      assert [%{id: "call_3", name: "n", args: %{}} = entry] =
               ReqLLMAdapter.normalize_tool_calls([tc])

      refute Map.has_key?(entry, :args_error)
    end
  end

  describe "build_messages/1" do
    test "prepends a plain system map when :system is present" do
      req = %{system: "sys", messages: [%{role: :user, content: "hi"}]}

      assert [
               %{role: :system, content: "sys"},
               %{role: :user, content: "hi"}
             ] = ReqLLMAdapter.build_messages(req)
    end

    test "omits the system message when :system is absent" do
      req = %{messages: [%{role: :user, content: "hi"}]}
      assert [%{role: :user, content: "hi"}] = ReqLLMAdapter.build_messages(req)
    end

    test "renders a tool-role message to a %Message{} with tool_call_id and text content" do
      req = %{
        messages: [%{role: :tool, content: "tool result", tool_call_id: "call_9"}]
      }

      assert [%Message{role: :tool, tool_call_id: "call_9", content: [part]}] =
               ReqLLMAdapter.build_messages(req)

      assert part.text == "tool result"
    end

    test "renders an assistant message carrying tool_calls to req_llm ToolCall structs" do
      req = %{
        messages: [
          %{
            role: :assistant,
            content: "thinking",
            tool_calls: [%{id: "call_9", function: %{name: "f", arguments: "{}"}}]
          }
        ]
      }

      assert [%Message{role: :assistant, content: [part], tool_calls: [tool_call]}] =
               ReqLLMAdapter.build_messages(req)

      assert part.text == "thinking"

      assert %ToolCall{id: "call_9", type: "function", function: %{name: "f", arguments: "{}"}} =
               tool_call
    end
  end
end
