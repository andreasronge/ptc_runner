defmodule PtcRunner.StepTest do
  use ExUnit.Case, async: true

  describe "Step struct" do
    test "creates step with all fields" do
      step = %PtcRunner.Step{
        return: %{count: 5},
        fail: nil,
        memory: %{"processed" => true},
        memory_delta: nil,
        signature: "() -> {count :int}",
        usage: %{duration_ms: 100, memory_bytes: 1024},
        trace: []
      }

      assert step.return == %{count: 5}
      assert step.fail == nil
      assert step.memory == %{"processed" => true}
      assert step.memory_delta == nil
      assert step.signature == "() -> {count :int}"
      assert step.usage == %{duration_ms: 100, memory_bytes: 1024}
      assert step.trace == []
    end

    test "supports pattern matching on successful step" do
      step = PtcRunner.Step.ok(%{value: 42}, %{})

      assert %PtcRunner.Step{return: return, fail: fail} = step
      assert return == %{value: 42}
      assert fail == nil
    end

    test "supports pattern matching on failed step" do
      step = PtcRunner.Step.error(:timeout, "Took too long", %{})

      assert %PtcRunner.Step{return: return, fail: fail} = step
      assert return == nil
      assert fail.reason == :timeout
      assert fail.message == "Took too long"
    end
  end

  describe "Step.ok/2" do
    test "creates successful step with return value and memory" do
      step = PtcRunner.Step.ok(%{count: 5}, %{"processed_ids" => [1, 2, 3]})

      assert step.return == %{count: 5}
      assert step.fail == nil
      assert step.memory == %{"processed_ids" => [1, 2, 3]}
      assert step.memory_delta == nil
      assert step.signature == nil
      assert step.usage == nil
      assert step.trace == nil
    end

    test "creates successful step with empty return" do
      step = PtcRunner.Step.ok(nil, %{})

      assert step.return == nil
      assert step.fail == nil
      assert step.memory == %{}
    end

    test "creates successful step with complex return value" do
      return_value = %{
        "items" => [%{"id" => 1, "name" => "Item 1"}],
        "metadata" => %{"total" => 1, "offset" => 0}
      }

      step = PtcRunner.Step.ok(return_value, %{})

      assert step.return == return_value
      assert step.fail == nil
    end

    test "creates successful step with list return" do
      step = PtcRunner.Step.ok([1, 2, 3], %{})

      assert step.return == [1, 2, 3]
      assert step.fail == nil
    end
  end

  describe "Step.error/3" do
    test "creates failed step with reason and message" do
      step = PtcRunner.Step.error(:timeout, "Execution exceeded time limit", %{})

      assert step.return == nil
      assert step.fail.reason == :timeout
      assert step.fail.message == "Execution exceeded time limit"
      assert step.memory == %{}
      assert step.memory_delta == nil
      assert step.signature == nil
      assert step.usage == nil
      assert step.trace == nil
    end

    test "creates failed step with various error reasons" do
      reasons = [
        :invalid_config,
        :parse_error,
        :analysis_error,
        :eval_error,
        :timeout,
        :memory_exceeded,
        :validation_error,
        :tool_error,
        :tool_not_found,
        :reserved_tool_name,
        :max_turns_exceeded,
        :max_depth_exceeded,
        :turn_budget_exhausted,
        :mission_timeout,
        :llm_error,
        :llm_not_found,
        :llm_registry_required,
        :invalid_llm,
        :chained_failure,
        :template_error
      ]

      Enum.each(reasons, fn reason ->
        step = PtcRunner.Step.error(reason, "Error message", %{})

        assert step.fail.reason == reason
        assert step.fail.message == "Error message"
        assert step.return == nil
      end)
    end

    test "creates failed step preserving memory" do
      memory = %{"processed_ids" => [1, 2, 3], "cache" => %{"key" => "value"}}
      step = PtcRunner.Step.error(:timeout, "Timeout occurred", memory)

      assert step.memory == memory
      assert step.fail.reason == :timeout
    end

    test "creates failed step with empty memory" do
      step = PtcRunner.Step.error(:parse_error, "Invalid syntax", %{})

      assert step.memory == %{}
      assert step.fail.reason == :parse_error
    end

    test "creates failed step with custom error reason" do
      step = PtcRunner.Step.error(:custom_error, "Custom error occurred", %{})

      assert step.fail.reason == :custom_error
      assert step.fail.message == "Custom error occurred"
    end
  end

  describe "fail field structure" do
    setup do
      base_step = %PtcRunner.Step{
        return: nil,
        fail: nil,
        memory: %{}
      }

      %{base_step: base_step}
    end

    test "fail field contains required fields only by default" do
      step = PtcRunner.Step.error(:timeout, "Message", %{})

      fail = step.fail

      assert Map.has_key?(fail, :reason)
      assert Map.has_key?(fail, :message)
      assert fail.reason == :timeout
      assert fail.message == "Message"
    end

    test "fail field can include optional op field", %{base_step: base_step} do
      fail = %{reason: :tool_error, message: "Tool failed", op: "search"}
      step = %{base_step | fail: fail}

      assert step.fail.op == "search"
    end

    test "fail field can include optional details field", %{base_step: base_step} do
      fail = %{
        reason: :validation_error,
        message: "Type mismatch",
        details: %{"expected" => "int", "got" => "string"}
      }

      step = %{base_step | fail: fail}

      assert step.fail.details == %{"expected" => "int", "got" => "string"}
    end

    test "fail field can include all optional fields", %{base_step: base_step} do
      fail = %{
        reason: :tool_error,
        message: "Tool execution failed",
        op: "database_query",
        details: %{"query" => "SELECT * FROM users", "error" => "Connection timeout"}
      }

      step = %{base_step | fail: fail}

      assert step.fail.reason == :tool_error
      assert step.fail.op == "database_query"

      assert step.fail.details == %{
               "query" => "SELECT * FROM users",
               "error" => "Connection timeout"
             }
    end
  end

  describe "usage field structure" do
    setup do
      base_step = %PtcRunner.Step{
        return: %{},
        fail: nil,
        memory: %{}
      }

      %{base_step: base_step}
    end

    test "usage field contains required fields", %{base_step: base_step} do
      usage = %{duration_ms: 245, memory_bytes: 1024}
      step = %{base_step | usage: usage}

      assert step.usage.duration_ms == 245
      assert step.usage.memory_bytes == 1024
    end

    test "usage field can include optional SubAgent metrics", %{base_step: base_step} do
      usage = %{
        duration_ms: 1000,
        memory_bytes: 4096,
        turns: 3,
        input_tokens: 150,
        output_tokens: 89,
        total_tokens: 239,
        llm_requests: 2
      }

      step = %{base_step | usage: usage}

      assert step.usage.turns == 3
      assert step.usage.input_tokens == 150
      assert step.usage.output_tokens == 89
      assert step.usage.total_tokens == 239
      assert step.usage.llm_requests == 2
    end

    test "usage field with only required metrics", %{base_step: base_step} do
      usage = %{duration_ms: 500, memory_bytes: 2048}
      step = %{base_step | usage: usage}

      assert step.usage == usage
      assert !Map.has_key?(step.usage, :turns)
      assert !Map.has_key?(step.usage, :input_tokens)
    end
  end

  describe "trace field structure" do
    setup do
      base_step = %PtcRunner.Step{
        return: %{count: 1},
        fail: nil,
        memory: %{}
      }

      %{base_step: base_step}
    end

    test "trace field contains list of trace entries", %{base_step: base_step} do
      tool_call = %{
        name: "search",
        args: %{"q" => "urgent"},
        result: [%{"id" => 1, "subject" => "Urgent"}],
        error: nil,
        timestamp: DateTime.utc_now(),
        duration_ms: 100
      }

      trace_entry = %{
        turn: 1,
        program: "(call \"search\" {:q \"urgent\"})",
        result: [%{"id" => 1}],
        tool_calls: [tool_call]
      }

      step = %{base_step | trace: [trace_entry]}

      assert length(step.trace) == 1
      assert hd(step.trace).turn == 1
      assert hd(step.trace).program == "(call \"search\" {:q \"urgent\"})"
    end

    test "trace field can contain multiple entries", %{base_step: base_step} do
      trace_entry_1 = %{
        turn: 1,
        program: "(call \"search\" {:q \"urgent\"})",
        result: [%{"id" => 1}],
        tool_calls: []
      }

      trace_entry_2 = %{
        turn: 2,
        program: "(call \"return\" {:count 1})",
        result: %{count: 1},
        tool_calls: []
      }

      step = %{base_step | trace: [trace_entry_1, trace_entry_2]}

      assert length(step.trace) == 2
      assert Enum.map(step.trace, & &1.turn) == [1, 2]
    end

    test "trace can be nil (for Lisp execution)" do
      step = PtcRunner.Step.ok(%{}, %{})

      assert step.trace == nil
    end
  end

  describe "mutual exclusivity of return and fail" do
    test "successful step has return, not fail" do
      step = PtcRunner.Step.ok(%{value: 42}, %{})

      assert step.return != nil
      assert step.fail == nil
    end

    test "failed step has fail, not return" do
      step = PtcRunner.Step.error(:timeout, "Timed out", %{})

      assert step.return == nil
      assert is_map(step.fail)
    end

    test "can manually create step with both nil" do
      step = %PtcRunner.Step{
        return: nil,
        fail: nil,
        memory: %{}
      }

      assert step.return == nil
      assert step.fail == nil
    end
  end

  describe "signature field" do
    test "signature field holds contract string" do
      step = %PtcRunner.Step{
        return: %{count: 5},
        fail: nil,
        memory: %{},
        signature: "() -> {count :int, _ids [:int]}"
      }

      assert step.signature == "() -> {count :int, _ids [:int]}"
    end

    test "signature can be nil" do
      step = PtcRunner.Step.ok(%{}, %{})

      assert step.signature == nil
    end

    test "signature with complex types" do
      signature = "(user {:id :int, :name :string}, limit :int) -> [{:id :int, :email :string?}]"

      step = %PtcRunner.Step{
        return: [],
        fail: nil,
        memory: %{},
        signature: signature
      }

      assert step.signature == signature
    end
  end

  describe "memory_delta field" do
    test "memory_delta contains changed keys (Lisp)" do
      step = %PtcRunner.Step{
        return: %{},
        fail: nil,
        memory: %{"processed_ids" => [1, 2, 3], "cache" => %{"key" => "value"}},
        memory_delta: %{"processed_ids" => [1, 2, 3]}
      }

      assert step.memory_delta == %{"processed_ids" => [1, 2, 3]}
    end

    test "memory_delta is nil for SubAgent" do
      step = %PtcRunner.Step{
        return: %{},
        fail: nil,
        memory: %{},
        memory_delta: nil
      }

      assert step.memory_delta == nil
    end

    test "memory_delta can be empty map" do
      step = %PtcRunner.Step{
        return: %{},
        fail: nil,
        memory: %{},
        memory_delta: %{}
      }

      assert step.memory_delta == %{}
    end
  end
end
