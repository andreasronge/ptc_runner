defmodule PtcRunner.TraceLogWriteToActiveTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TraceLog

  @moduletag :tmp_dir

  describe "write_to_active/1" do
    test "returns :no_collector when called outside a with_trace scope" do
      # Sanity: no active trace in this process.
      assert TraceLog.current_collector() == nil
      assert TraceLog.write_to_active(%{"event" => "foo"}) == :no_collector
    end

    test "writes a parseable JSONL line to the active trace inside with_trace/2",
         %{tmp_dir: dir} do
      path = Path.join(dir, "write_to_active.jsonl")

      {:ok, :done, ^path} =
        TraceLog.with_trace(
          fn ->
            event = %{
              "schema_version" => 2,
              "event" => "phase05.write_to_active",
              "trace_id" => "phase05-test",
              "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "data" => %{"hello" => "world", "n" => 42}
            }

            assert TraceLog.write_to_active(event) == :ok
            :done
          end,
          path: path,
          trace_id: "phase05-test"
        )

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)

      decoded = Enum.map(lines, &Jason.decode!/1)

      # Find our event among the trace.start / trace.stop lines the
      # collector emits automatically.
      our_event =
        Enum.find(decoded, fn ev -> ev["event"] == "phase05.write_to_active" end)

      assert our_event, "expected phase05.write_to_active event in #{inspect(decoded)}"
      assert our_event["trace_id"] == "phase05-test"
      assert get_in(our_event, ["data", "hello"]) == "world"
      assert get_in(our_event, ["data", "n"]) == 42
      # Collector assigns a positive sequence number.
      assert is_integer(our_event["seq"]) and our_event["seq"] > 0
    end

    test "uses the innermost (most recently pushed) collector when traces are nested",
         %{tmp_dir: dir} do
      outer_path = Path.join(dir, "outer.jsonl")
      inner_path = Path.join(dir, "inner.jsonl")

      {:ok, :done, ^outer_path} =
        TraceLog.with_trace(
          fn ->
            {:ok, :inner_done, ^inner_path} =
              TraceLog.with_trace(
                fn ->
                  assert TraceLog.write_to_active(%{
                           "event" => "inner.only",
                           "trace_id" => "inner",
                           "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
                           "data" => %{"where" => "inner"}
                         }) == :ok

                  :inner_done
                end,
                path: inner_path,
                trace_id: "inner"
              )

            assert TraceLog.write_to_active(%{
                     "event" => "outer.only",
                     "trace_id" => "outer",
                     "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
                     "data" => %{"where" => "outer"}
                   }) == :ok

            :done
          end,
          path: outer_path,
          trace_id: "outer"
        )

      inner_events =
        inner_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      outer_events =
        outer_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(inner_events, &(&1["event"] == "inner.only"))
      refute Enum.any?(inner_events, &(&1["event"] == "outer.only"))

      assert Enum.any?(outer_events, &(&1["event"] == "outer.only"))
      refute Enum.any?(outer_events, &(&1["event"] == "inner.only"))
    end

    test "returns :no_collector and never raises when given a non-map" do
      assert TraceLog.write_to_active(:not_a_map) == :no_collector
      assert TraceLog.write_to_active(nil) == :no_collector
      assert TraceLog.write_to_active("string") == :no_collector
    end
  end
end
