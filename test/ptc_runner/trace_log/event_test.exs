defmodule PtcRunner.TraceLog.EventTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TraceLog.Event

  doctest Event

  describe "from_telemetry/4" do
    test "creates event with correct structure" do
      event = [:ptc_runner, :sub_agent, :run, :start]
      measurements = %{system_time: 1000}
      metadata = %{agent: "test"}

      result = Event.from_telemetry(event, measurements, metadata, "trace-123")

      assert result["event"] == "run.start"
      assert result["trace_id"] == "trace-123"
      assert is_binary(result["timestamp"])
      assert result["measurements"]["system_time"] == 1000
      assert result["metadata"]["agent"] == "test"
    end

    test "handles nested event names" do
      event = [:ptc_runner, :sub_agent, :llm, :stop]
      result = Event.from_telemetry(event, %{}, %{}, "trace-123")
      assert result["event"] == "llm.stop"
    end
  end

  describe "sanitize/1" do
    test "converts PIDs to strings" do
      result = Event.sanitize(self())
      assert is_binary(result)
      assert String.starts_with?(result, "#PID<")
    end

    test "converts references to strings" do
      ref = make_ref()
      result = Event.sanitize(ref)
      assert is_binary(result)
      assert String.starts_with?(result, "#Reference<")
    end

    test "converts functions to strings" do
      fun = fn x -> x end
      result = Event.sanitize(fun)
      assert is_binary(result)
      assert String.starts_with?(result, "#Function<")
    end

    test "handles non-printable binaries" do
      binary = <<0, 1, 2, 3, 255>>
      result = Event.sanitize(binary)
      assert result == %{"__binary__" => true, "size" => 5}
    end

    test "keeps small printable strings" do
      string = "hello world"
      assert Event.sanitize(string) == "hello world"
    end

    test "summarizes large strings (>1KB) with preview" do
      large_string = String.duplicate("a", 2000)
      result = Event.sanitize(large_string)
      assert result =~ String.duplicate("a", 200) <> "..."
      assert result =~ "[String truncated — 2000 bytes total]"
    end

    test "keeps small lists" do
      list = [1, 2, 3]
      assert Event.sanitize(list) == [1, 2, 3]
    end

    test "summarizes large lists (>100 items)" do
      large_list = Enum.to_list(1..150)
      result = Event.sanitize(large_list)
      assert result == "List(150 items)"
    end

    test "recursively sanitizes maps" do
      map = %{pid: self(), value: 42}
      result = Event.sanitize(map)
      assert is_binary(result["pid"])
      assert result["value"] == 42
    end

    test "converts atom keys to strings" do
      map = %{foo: 1, bar: 2}
      result = Event.sanitize(map)
      assert result == %{"foo" => 1, "bar" => 2}
    end

    test "converts structs to maps" do
      struct = %URI{host: "example.com", path: "/test"}
      result = Event.sanitize(struct)
      assert is_map(result)
      assert result["host"] == "example.com"
      assert result["path"] == "/test"
    end

    test "converts tuples to lists" do
      tuple = {:ok, "result", 42}
      result = Event.sanitize(tuple)
      assert result == [:ok, "result", 42]
    end

    test "preserves atoms" do
      assert Event.sanitize(:foo) == :foo
    end

    test "preserves numbers" do
      assert Event.sanitize(42) == 42
      assert Event.sanitize(3.14) == 3.14
    end

    test "handles deeply nested structures" do
      nested = %{
        level1: %{
          level2: %{
            pid: self(),
            list: [1, 2, 3]
          }
        }
      }

      result = Event.sanitize(nested)
      assert is_binary(result["level1"]["level2"]["pid"])
      assert result["level1"]["level2"]["list"] == [1, 2, 3]
    end
  end

  describe "encode/1" do
    test "encodes valid event to JSON" do
      event = %{"event" => "test", "trace_id" => "123"}
      assert {:ok, json} = Event.encode(event)
      assert is_binary(json)
      assert Jason.decode!(json) == event
    end
  end

  describe "encode!/1" do
    test "encodes valid event to JSON" do
      event = %{"event" => "test", "trace_id" => "123"}
      json = Event.encode!(event)
      assert Jason.decode!(json) == event
    end
  end
end
