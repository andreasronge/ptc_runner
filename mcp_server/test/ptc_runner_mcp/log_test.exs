defmodule PtcRunnerMcp.LogTest do
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Log

  setup do
    prior = Log.level()
    on_exit(fn -> Log.set_level(prior) end)
    :ok
  end

  test "emits a single JSON line per event with ts/level/event" do
    Log.set_level(:debug)

    line =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Log.log(:info, "test_event", %{request_id: 7, tool: "lisp_eval"})
      end)

    assert String.ends_with?(line, "\n")
    [json | _] = String.split(line, "\n", trim: true)
    decoded = Jason.decode!(json)

    assert decoded["event"] == "test_event"
    assert decoded["level"] == "info"
    assert is_binary(decoded["ts"])
    assert decoded["request_id"] == "7"
    assert decoded["fields"] == %{"tool" => "lisp_eval"}
  end

  test "below-level events emit nothing" do
    Log.set_level(:warn)

    line =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Log.log(:info, "noisy", %{})
      end)

    assert line == ""
  end

  test "set_level accepts strings and atoms" do
    assert :ok == Log.set_level("debug")
    assert Log.level() == :debug
    assert :ok == Log.set_level(:warn)
    assert Log.level() == :warn
    assert :ok == Log.set_level("WARNING")
    assert Log.level() == :warn
    assert :ok == Log.set_level("nonsense")
    assert Log.level() == :info
  end
end
