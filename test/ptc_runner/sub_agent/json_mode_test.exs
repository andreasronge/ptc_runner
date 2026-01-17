defmodule PtcRunner.SubAgent.JsonModeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  describe "JSON mode routing" do
    test "routes to JSON mode when output: :json" do
      agent =
        SubAgent.new(
          prompt: "Return greeting",
          output: :json,
          signature: "() -> {message :string}",
          max_turns: 2
        )

      llm = fn _input ->
        {:ok, ~s|{"message": "hello"}|}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == %{message: "hello"}
      assert step.memory == %{}
    end

    test "routes to PTC-Lisp mode when output: :ptc_lisp (default)" do
      agent =
        SubAgent.new(
          prompt: "Return greeting",
          signature: "() -> {message :string}",
          max_turns: 2
        )

      assert agent.output == :ptc_lisp

      llm = fn _input ->
        {:ok, ~S|```clojure
(return {:message "hello"})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == %{message: "hello"}
    end
  end

  describe "JSON mode success cases" do
    test "parses valid JSON response" do
      agent =
        SubAgent.new(
          prompt: "Classify sentiment",
          output: :json,
          signature: "() -> {sentiment :string, score :float}",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ~s|{"sentiment": "positive", "score": 0.95}|}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == %{sentiment: "positive", score: 0.95}
      assert step.memory == %{}
      assert step.fail == nil
    end

    test "handles JSON in markdown code block" do
      agent =
        SubAgent.new(
          prompt: "Extract data",
          output: :json,
          signature: "() -> {count :int}",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok,
         """
         Here's the result:
         ```json
         {"count": 42}
         ```
         """}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == %{count: 42}
    end

    test "converts string keys to atoms" do
      agent =
        SubAgent.new(
          prompt: "Return data",
          output: :json,
          signature: "() -> {name :string, age :int}",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ~s|{"name": "Alice", "age": 30}|}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == %{name: "Alice", age: 30}
      assert is_atom(hd(Map.keys(step.return)))
    end

    test "handles nested structures" do
      agent =
        SubAgent.new(
          prompt: "Return nested data",
          output: :json,
          signature: "() -> {user {name :string, emails [:string]}}",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ~s|{"user": {"name": "Bob", "emails": ["a@b.com", "c@d.com"]}}|}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == %{user: %{name: "Bob", emails: ["a@b.com", "c@d.com"]}}
    end

    test "passes output: :json and schema to LLM callback" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 1
        )

      test_pid = self()

      llm = fn input ->
        send(test_pid, {:llm_input, input})
        {:ok, ~s|{"value": 123}|}
      end

      {:ok, _step} = Loop.run(agent, llm: llm)

      assert_receive {:llm_input, input}
      assert input.output == :json

      assert input.schema == %{
               "type" => "object",
               "properties" => %{"value" => %{"type" => "integer"}},
               "required" => ["value"],
               "additionalProperties" => false
             }
    end

    test "includes context data in user message" do
      agent =
        SubAgent.new(
          prompt: "Analyze {{text}}",
          output: :json,
          signature: "(text :string) -> {length :int}",
          max_turns: 1
        )

      test_pid = self()

      llm = fn input ->
        send(test_pid, {:llm_input, input})
        {:ok, ~s|{"length": 11}|}
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{text: "hello world"})

      assert_receive {:llm_input, input}
      [user_msg] = input.messages
      assert user_msg.content =~ "hello world"
      assert user_msg.content =~ "Analyze hello world"
    end
  end

  describe "JSON mode validation and retry" do
    test "retries on validation error" do
      agent =
        SubAgent.new(
          prompt: "Return value",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 3
        )

      call_count = :counters.new(1, [:atomics])

      llm = fn _input ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case count do
          0 -> {:ok, ~s|{"value": "not an int"}|}
          _ -> {:ok, ~s|{"value": 42}|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == %{value: 42}
      assert length(step.turns) == 2
    end

    test "retries on parse error" do
      agent =
        SubAgent.new(
          prompt: "Return value",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 3
        )

      call_count = :counters.new(1, [:atomics])

      llm = fn _input ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case count do
          0 -> {:ok, "This is not JSON at all"}
          _ -> {:ok, ~s|{"value": 42}|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == %{value: 42}
      assert length(step.turns) == 2
    end

    test "fails after max_turns validation errors" do
      agent =
        SubAgent.new(
          prompt: "Return value",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 2
        )

      llm = fn _input ->
        {:ok, ~s|{"wrong": "field"}|}
      end

      {:error, step} = Loop.run(agent, llm: llm)

      assert step.fail.reason == :validation_error
      assert step.fail.message =~ "value"
      assert length(step.turns) == 2
    end

    test "fails after max_turns exceeded with parse errors" do
      agent =
        SubAgent.new(
          prompt: "Return value",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 2
        )

      llm = fn _input ->
        {:ok, "not json"}
      end

      {:error, step} = Loop.run(agent, llm: llm)

      assert step.fail.reason == :json_parse_error
    end

    test "error feedback includes expected format" do
      agent =
        SubAgent.new(
          prompt: "Return value",
          output: :json,
          signature: "() -> {message :string}",
          max_turns: 2
        )

      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      llm = fn input ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count > 0 do
          # Second call - capture the error feedback
          [_, _, user_msg] = input.messages
          send(test_pid, {:error_feedback, user_msg.content})
        end

        case count do
          0 -> {:ok, "invalid"}
          _ -> {:ok, ~s|{"message": "ok"}|}
        end
      end

      {:ok, _step} = Loop.run(agent, llm: llm)

      assert_receive {:error_feedback, feedback}
      assert feedback =~ "not valid JSON"
      assert feedback =~ "message"
    end
  end

  describe "JSON mode metrics and tracing" do
    test "includes usage metrics" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, %{content: ~s|{"value": 1}|, tokens: %{input: 10, output: 5}}}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.usage.duration_ms >= 0
      assert step.usage.input_tokens == 10
      assert step.usage.output_tokens == 5
      assert step.usage.turns == 1
    end

    test "includes trace when enabled" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ~s|{"value": 1}|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, trace: true)

      assert length(step.turns) == 1
      [turn] = step.turns
      assert turn.number == 1
      assert turn.success?
    end

    test "omits trace when disabled" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ~s|{"value": 1}|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, trace: false)

      assert step.turns == nil
    end

    test "collects messages when enabled" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ~s|{"value": 1}|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, collect_messages: true)

      assert is_list(step.messages)
      assert length(step.messages) == 3
      [system_msg, user_msg, assistant_msg] = step.messages
      assert system_msg.role == :system
      assert user_msg.role == :user
      assert assistant_msg.role == :assistant
    end
  end

  describe "JSON mode with SubAgent.run/2" do
    test "works through SubAgent.run/2 entry point" do
      agent =
        SubAgent.new(
          prompt: "Return greeting",
          output: :json,
          signature: "() -> {message :string}",
          max_turns: 2
        )

      llm = fn _input ->
        {:ok, ~s|{"message": "hello"}|}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{message: "hello"}
    end

    test "string convenience form works with output: :json" do
      llm = fn _input ->
        {:ok, ~s|{"result": 42}|}
      end

      {:ok, step} =
        SubAgent.run(
          "Return 42",
          llm: llm,
          output: :json,
          signature: "() -> {result :int}",
          max_turns: 1
        )

      assert step.return == %{result: 42}
    end
  end

  describe "JSON mode piping" do
    test "JSON -> PTC-Lisp piping works" do
      json_agent =
        SubAgent.new(
          prompt: "Get number",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 1
        )

      ptc_agent =
        SubAgent.new(
          prompt: "Double {{value}}",
          signature: "(value :int) -> {result :int}",
          max_turns: 2
        )

      json_llm = fn _input ->
        {:ok, ~s|{"value": 21}|}
      end

      ptc_llm = fn _input ->
        {:ok, ~S|```clojure
(return {:result (* 2 data/value)})
```|}
      end

      {:ok, step1} = SubAgent.run(json_agent, llm: json_llm)
      assert step1.return == %{value: 21}

      {:ok, step2} = SubAgent.run(ptc_agent, llm: ptc_llm, context: step1)
      assert step2.return == %{result: 42}
    end

    test "PTC-Lisp -> JSON piping works" do
      ptc_agent =
        SubAgent.new(
          prompt: "Get number",
          signature: "() -> {value :int}",
          max_turns: 2
        )

      json_agent =
        SubAgent.new(
          prompt: "Double {{value}}",
          output: :json,
          signature: "(value :int) -> {result :int}",
          max_turns: 1
        )

      ptc_llm = fn _input ->
        {:ok, ~S|```clojure
(return {:value 21})
```|}
      end

      json_llm = fn _input ->
        {:ok, ~s|{"result": 42}|}
      end

      {:ok, step1} = SubAgent.run(ptc_agent, llm: ptc_llm)
      assert step1.return == %{value: 21}

      {:ok, step2} = SubAgent.run(json_agent, llm: json_llm, context: step1)
      assert step2.return == %{result: 42}
    end

    test "JSON -> JSON piping works" do
      agent1 =
        SubAgent.new(
          prompt: "Step 1",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 1
        )

      agent2 =
        SubAgent.new(
          prompt: "Step 2 with {{value}}",
          output: :json,
          signature: "(value :int) -> {doubled :int}",
          max_turns: 1
        )

      llm1 = fn _input -> {:ok, ~s|{"value": 10}|} end
      llm2 = fn _input -> {:ok, ~s|{"doubled": 20}|} end

      {:ok, step1} = SubAgent.run(agent1, llm: llm1)
      {:ok, step2} = SubAgent.run(agent2, llm: llm2, context: step1)

      assert step2.return == %{doubled: 20}
    end
  end

  describe "JSON mode array return type" do
    test "accepts array when signature expects list" do
      agent =
        SubAgent.new(
          prompt: "Return IDs",
          output: :json,
          signature: "() -> [:int]",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ~s|[1, 2, 3]|}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == [1, 2, 3]
    end

    test "accepts array of objects when signature expects list of maps" do
      agent =
        SubAgent.new(
          prompt: "Return items",
          output: :json,
          signature: "() -> [{id :int, name :string}]",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ~s|[{"id": 1, "name": "a"}, {"id": 2, "name": "b"}]|}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == [%{id: 1, name: "a"}, %{id: 2, name: "b"}]
    end

    test "validates array elements against signature type" do
      agent =
        SubAgent.new(
          prompt: "Return IDs",
          output: :json,
          signature: "() -> [:int]",
          max_turns: 2
        )

      call_count = :counters.new(1, [:atomics])

      llm = fn _input ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case count do
          0 -> {:ok, ~s|["not", "ints"]|}
          _ -> {:ok, ~s|[1, 2, 3]|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == [1, 2, 3]
      assert length(step.turns) == 2
    end

    test "rejects array when signature expects object" do
      agent =
        SubAgent.new(
          prompt: "Return object",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ~s|[1, 2, 3]|}
      end

      {:error, step} = Loop.run(agent, llm: llm)

      assert step.fail.message =~ "must be a JSON object"
    end
  end

  describe "JSON mode preview_prompt" do
    test "preview_prompt returns JSON mode format" do
      agent =
        SubAgent.new(
          prompt: "Return IDs for {{topic}}",
          output: :json,
          signature: "(topic :string, items [{id :int}]) -> [:int]",
          max_turns: 1
        )

      context = %{topic: "test", items: [%{id: 1}, %{id: 2}]}
      preview = SubAgent.preview_prompt(agent, context: context)

      # System prompt should be JSON mode prompt
      assert preview.system =~ "structured JSON"
      refute preview.system =~ "PTC-Lisp"

      # User message should have JSON formatted data (not Elixir format)
      assert preview.user =~ ~s|`topic`: "test"|
      assert preview.user =~ ~s|[{"id":1},{"id":2}]|
      refute preview.user =~ "%{id:"

      # Should include task and expected output
      assert preview.user =~ "Return IDs for test"
      assert preview.user =~ "Expected Output"
    end

    test "preview_prompt matches actual LLM input" do
      agent =
        SubAgent.new(
          prompt: "Classify {{text}}",
          output: :json,
          signature: "(text :string) -> {label :string}",
          max_turns: 1
        )

      context = %{text: "hello world"}
      preview = SubAgent.preview_prompt(agent, context: context)

      # Capture actual LLM input
      test_pid = self()

      llm = fn input ->
        send(test_pid, {:llm_input, input})
        {:ok, ~s|{"label": "greeting"}|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, context: context)

      assert_receive {:llm_input, input}

      # Preview should match actual input
      assert preview.system == input.system
      assert preview.user == hd(input.messages).content
    end
  end

  describe "JSON mode edge cases" do
    test "handles empty context" do
      agent =
        SubAgent.new(
          prompt: "Return value",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ~s|{"value": 1}|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{value: 1}
    end

    test "handles :any return type in signature" do
      agent =
        SubAgent.new(
          prompt: "Return value",
          output: :json,
          signature: "() -> :any",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ~s|{"anything": "works"}|}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == %{anything: "works"}
    end

    test "handles LLM error" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 1
        )

      llm = fn _input ->
        {:error, :network_error}
      end

      {:error, step} = Loop.run(agent, llm: llm)

      assert step.fail.reason == :llm_error
    end

    test "respects turn_budget" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {value :int}",
          max_turns: 10,
          turn_budget: 1
        )

      llm = fn _input ->
        {:ok, ~s|{"wrong": "field"}|}
      end

      {:error, step} = Loop.run(agent, llm: llm, _remaining_turns: 0)

      assert step.fail.reason == :turn_budget_exhausted
    end

    test "field_descriptions are included in step" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {sentiment :string}",
          field_descriptions: %{sentiment: "The detected sentiment"},
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ~s|{"sentiment": "positive"}|}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.field_descriptions == %{sentiment: "The detected sentiment"}
    end
  end
end
