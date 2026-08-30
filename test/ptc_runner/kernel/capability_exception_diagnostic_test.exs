defmodule PtcRunner.Kernel.CapabilityExceptionDiagnosticTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CapabilityExceptionDiagnostic
  alias PtcRunner.Kernel.InspectionRecordTypes
  alias PtcRunner.TestSupport.ObservedException

  test "bounds messages at valid UTF-8 byte boundaries" do
    for {message, truncated?} <- [
          {String.duplicate("x", 4_096), false},
          {String.duplicate("x", 4_097), true},
          {String.duplicate("å", 2_049), true}
        ] do
      diagnostic =
        CapabilityExceptionDiagnostic.capture(%ObservedException{value: message}, [])

      assert diagnostic.message_truncated == truncated?
      assert String.valid?(diagnostic.message)

      assert byte_size(diagnostic.message) <=
               InspectionRecordTypes.max_exception_message_bytes()
    end
  end

  test "limits formatted stacktrace frames and bytes" do
    long_file = String.duplicate("x", 2_000) |> String.to_charlist()
    frame = {__MODULE__, :fixture, 0, [file: long_file, line: 1]}

    diagnostic =
      CapabilityExceptionDiagnostic.capture(
        %ObservedException{value: "boom"},
        List.duplicate(frame, 65)
      )

    assert diagnostic.stacktrace_truncated
    assert String.valid?(diagnostic.stacktrace)

    assert byte_size(diagnostic.stacktrace) <=
             InspectionRecordTypes.max_exception_stacktrace_bytes()
  end

  test "formats stack frames without inspecting callback arguments" do
    diagnostic =
      CapabilityExceptionDiagnostic.capture(
        %ObservedException{value: "boom"},
        [{__MODULE__, :fixture, ["private-argument-secret"], [file: ~c"private.ex", line: 1]}]
      )

    assert diagnostic.stacktrace =~ "fixture/1"
    refute diagnostic.stacktrace =~ "private-argument-secret"
  end

  test "a broken exception message formatter cannot mask the diagnostic" do
    diagnostic =
      CapabilityExceptionDiagnostic.capture(%ObservedException{mode: :raise}, [])

    assert diagnostic.message == "exception message unavailable"
    assert diagnostic.message_truncated
    assert diagnostic.exception_class == "Elixir.PtcRunner.TestSupport.ObservedException"
  end

  test "an unclaimed diagnostic worker expires without retaining its exception" do
    assert {:ok, pid, _exception_class} =
             CapabilityExceptionDiagnostic.start(
               %ObservedException{value: "private"},
               [],
               self()
             )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end
end
