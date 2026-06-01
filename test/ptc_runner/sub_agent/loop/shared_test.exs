defmodule PtcRunner.SubAgent.Loop.SharedTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.Loop.Shared

  describe "check_memory_limit/2" do
    test "nil limit is always within bounds" do
      assert Shared.check_memory_limit(%{anything: :goes}, nil) == {:ok, 0}
    end

    test "returns {:ok, size} when under the limit" do
      assert {:ok, size} = Shared.check_memory_limit(%{a: 1}, 1_000_000)
      assert is_integer(size) and size > 0
    end

    test "returns memory_limit_exceeded with the actual size when over" do
      assert {:error, :memory_limit_exceeded, size} = Shared.check_memory_limit(%{a: 1}, 0)
      assert size == Shared.memory_size(%{a: 1})
    end
  end

  describe "classify_lisp_error/1" do
    test "passes through canonical reasons" do
      for reason <- [:parse_error, :timeout, :memory_limit] do
        assert Shared.classify_lisp_error(%{reason: reason}) == reason
      end
    end

    test "maps substring reasons onto canonical atoms" do
      assert Shared.classify_lisp_error(%{reason: :json_parse_failure}) == :parse_error
      assert Shared.classify_lisp_error(%{reason: :exec_timeout}) == :timeout
      assert Shared.classify_lisp_error(%{reason: :out_of_memory}) == :memory_limit
    end

    test "falls back to runtime_error for unrecognized reasons" do
      assert Shared.classify_lisp_error(%{reason: :boom}) == :runtime_error
    end

    test "handles string reasons (Step.fail allows atom | String)" do
      assert Shared.classify_lisp_error(%{reason: "json parse failure"}) == :parse_error
      assert Shared.classify_lisp_error(%{reason: "exec timeout"}) == :timeout
      assert Shared.classify_lisp_error(%{reason: "out of memory"}) == :memory_limit
      assert Shared.classify_lisp_error(%{reason: "kaboom"}) == :runtime_error
    end
  end

  describe "parse_for_type/2" do
    test ":datetime accepts a bare ISO-8601 string" do
      assert Shared.parse_for_type("2026-05-06T12:00:00Z", :datetime) ==
               {:ok, "2026-05-06T12:00:00Z"}
    end

    test ":datetime accepts a JSON-quoted string" do
      assert Shared.parse_for_type(~s("hello"), :datetime) == {:ok, "hello"}
    end

    test ":datetime reports a clear error for garbage" do
      assert {:error, message} = Shared.parse_for_type("not-a-date", :datetime)
      assert message =~ "Could not parse datetime"
    end

    test "other types decode JSON" do
      assert Shared.parse_for_type("[1, 2, 3]", :any) == {:ok, [1, 2, 3]}
      assert Shared.parse_for_type("{\"a\": 1}", {:optional, :map}) == {:ok, %{"a" => 1}}
    end

    test "other types report a JSON parse error" do
      assert Shared.parse_for_type("nope", :any) ==
               {:error, "Could not parse JSON from response."}
    end
  end

  describe "build_collected_messages/2" do
    test "returns nil when collection is disabled" do
      assert Shared.build_collected_messages(%{collect_messages: false}, [:msg]) == nil
    end

    test "prepends the current system prompt when enabled" do
      state = %{collect_messages: true, current_system_prompt: "SYS"}
      messages = [%{role: :user, content: "hi"}]

      assert Shared.build_collected_messages(state, messages) ==
               [%{role: :system, content: "SYS"} | messages]
    end

    test "uses an empty system prompt when none is set" do
      state = %{collect_messages: true, current_system_prompt: nil}
      assert [%{role: :system, content: ""} | _] = Shared.build_collected_messages(state, [])
    end
  end

  describe "add_schema_metrics/2" do
    test "records usage and byte size for a map schema" do
      usage = Shared.add_schema_metrics(%{}, %{"type" => "object"})
      assert usage.schema_used == true
      assert usage.schema_bytes == byte_size(Jason.encode!(%{"type" => "object"}))
    end

    test "marks schema unused for a non-map schema" do
      assert Shared.add_schema_metrics(%{}, nil) == %{schema_used: false}
    end
  end
end
