defmodule PtcRunner.TraceLog.TurnEventTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TraceLog.TurnEvent

  describe "build/1" do
    test "produces the canonical top-level shape for a session turn" do
      event =
        TurnEvent.build(%{
          driver: :session,
          session_id: "sess-1",
          turn: 3,
          attempt: 5,
          committed: true,
          status: :ok,
          duration_ms: 12,
          program: "(inc x)",
          result_preview: "42",
          prints: ["hi"]
        })

      assert event["schema_version"] == 2
      assert event["event"] == "turn"
      assert event["driver"] == "session"
      assert event["session_id"] == "sess-1"
      assert event["agent_id"] == nil
      assert event["turn"] == 3
      assert event["attempt"] == 5
      assert event["committed"] == true
      assert event["status"] == "ok"
      assert event["duration_ms"] == 12
      assert event["data"]["program"] == "(inc x)"
      assert event["data"]["result_preview"] == "42"
      assert event["data"]["prints"] == ["hi"]
      # The sink stamps these; the builder must not.
      refute Map.has_key?(event, "trace_id")
      refute Map.has_key?(event, "seq")
      refute Map.has_key?(event, "timestamp")
    end

    test "a sub_agent turn shares the SAME top-level keys as a session turn" do
      session = TurnEvent.build(%{driver: :session, session_id: "s", turn: 1, status: :ok})
      sub_agent = TurnEvent.build(%{driver: :sub_agent, agent_id: "a", turn: 1, status: :error})

      assert Map.keys(session) == Map.keys(sub_agent)
      assert Map.keys(session["data"]) == Map.keys(sub_agent["data"])
      assert sub_agent["driver"] == "sub_agent"
      assert sub_agent["status"] == "error"
    end

    test "is JSON-encodable and sanitizes the data bag" do
      event =
        TurnEvent.build(%{
          driver: :session,
          status: :error,
          fail: %{reason: :runtime_error, message: "boom"},
          memory_diff: %{changed_keys: ["x"], values: %{"x" => self()}},
          turn_type: :retry
        })

      assert {:ok, _json} = Jason.encode(event)
      assert event["data"]["fail"] == %{"reason" => "runtime_error", "message" => "boom"}
      assert event["data"]["turn_type"] == "retry"
      # A pid is sanitized to its inspect string, never raw.
      assert event["data"]["memory_diff"]["values"]["x"] =~ "#PID<"
    end

    test "committed defaults to false and coerces truthy-but-not-true to false" do
      assert TurnEvent.build(%{driver: :session})["committed"] == false
      assert TurnEvent.build(%{driver: :session, committed: "yes"})["committed"] == false
      assert TurnEvent.build(%{driver: :session, committed: true})["committed"] == true
    end
  end

  describe "memory_diff/2" do
    test "reports added and rebound keys with their post-turn values" do
      assert TurnEvent.memory_diff(%{"a" => 1}, %{"a" => 1, "b" => 2}) ==
               %{changed_keys: ["b"], values: %{"b" => 2}}

      assert TurnEvent.memory_diff(%{"a" => 1}, %{"a" => 9}) ==
               %{changed_keys: ["a"], values: %{"a" => 9}}
    end

    test "returns nil when nothing changed" do
      assert TurnEvent.memory_diff(%{"a" => 1}, %{"a" => 1}) == nil
      assert TurnEvent.memory_diff(%{}, %{}) == nil
    end

    test "treats a newly added nil-valued binding as a change" do
      # `(def x nil)`: a missing key and a nil value both read as nil via
      # Map.get, so presence must be checked separately.
      assert TurnEvent.memory_diff(%{}, %{"x" => nil}) ==
               %{changed_keys: ["x"], values: %{"x" => nil}}

      # Rebinding an existing key to nil is also a change.
      assert TurnEvent.memory_diff(%{"x" => 1}, %{"x" => nil}) ==
               %{changed_keys: ["x"], values: %{"x" => nil}}

      # An unchanged nil binding is not a change.
      assert TurnEvent.memory_diff(%{"x" => nil}, %{"x" => nil}) == nil
    end

    test "returns nil for non-map inputs" do
      assert TurnEvent.memory_diff(nil, %{"a" => 1}) == nil
      assert TurnEvent.memory_diff(%{"a" => 1}, nil) == nil
    end
  end

  describe "preview/1" do
    test "renders nil and bounds long values" do
      assert TurnEvent.preview(nil) == "nil"
      assert TurnEvent.preview([1, 2, 3]) == "[1, 2, 3]"

      long = String.duplicate("x", 10_000)
      preview = TurnEvent.preview(long)
      assert String.length(preview) <= 4_096
      assert String.ends_with?(preview, "...")
    end
  end
end
