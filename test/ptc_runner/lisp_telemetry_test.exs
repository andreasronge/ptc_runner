defmodule PtcRunner.LispTelemetryTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Lisp

  @events [
    [:ptc_runner, :lisp, :execute, :start],
    [:ptc_runner, :lisp, :execute, :stop],
    [:ptc_runner, :lisp, :execute, :exception]
  ]

  setup do
    test_pid = self()
    handler_id = "lisp-telemetry-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      @events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "Lisp.run/2 telemetry" do
    test "emits bounded start and successful stop measurements" do
      assert {:ok, _step} = Lisp.run("(+ 1 2)")

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], start_meas, start_meta}
      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :stop], stop_meas, stop_meta}

      assert Map.keys(start_meas) |> Enum.sort() == [:monotonic_time, :system_time]

      assert start_meta == %{
               caller: :direct,
               program_bytes: byte_size("(+ 1 2)"),
               signature_supplied?: false
             }

      assert Map.keys(stop_meas) |> Enum.sort() ==
               [:duration, :monotonic_time, :prints_count, :result_bytes]

      assert is_integer(stop_meas.duration)
      assert stop_meas.result_bytes > 0
      assert stop_meas.prints_count == 0
      assert stop_meta == Map.put(start_meta, :outcome, :ok)
    end

    test "accepts only the direct, kernel, and repl caller taxonomy" do
      for caller <- [:direct, :kernel, :repl] do
        assert {:ok, _} = Lisp.run("(+ 1 2)", caller: caller)

        assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _, %{caller: ^caller}}

        assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :stop], _, %{caller: ^caller}}
      end

      assert_raise ArgumentError, fn -> Lisp.run("(+ 1 2)", caller: :mcp) end
      assert_raise ArgumentError, fn -> Lisp.run("(+ 1 2)", caller: :in_process_v1) end
    end

    test "invalid caller fails before telemetry is emitted" do
      flush_telemetry()

      assert_raise ArgumentError, fn -> Lisp.run("(+ 1 2)", caller: :bogus) end
      refute_received {:telemetry, [:ptc_runner, :lisp, :execute, _], _, _}
    end

    test "signature_supplied? is true when a signature is supplied" do
      assert {:ok, _} = Lisp.run("(+ 1 2)", signature: "() -> :int")

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _,
                      %{signature_supplied?: true}}

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :stop], _,
                      %{signature_supplied?: true}}
    end

    test "recoverable Lisp failures emit a semantic error outcome" do
      assert {:error, _} = Lisp.run("(+ undefined-var 1)", caller: :kernel)

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _, %{caller: :kernel}}

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :stop], _,
                      %{caller: :kernel, outcome: :error}}

      refute_received {:telemetry, [:ptc_runner, :lisp, :execute, :exception], _, _}
    end

    test "exception metadata identifies only its class, never raw reason or stacktrace" do
      assert_raise Protocol.UndefinedError, fn ->
        Lisp.run("1", tools: :not_enumerable, caller: :repl)
      end

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _, %{caller: :repl}}

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :exception], measurements,
                      metadata}

      assert Map.keys(measurements) |> Enum.sort() == [:duration, :monotonic_time]

      assert metadata == %{
               caller: :repl,
               exception_class: Protocol.UndefinedError,
               program_bytes: 1,
               signature_supplied?: false
             }
    end
  end

  defp flush_telemetry do
    receive do
      {:telemetry, _, _, _} -> flush_telemetry()
    after
      0 -> :ok
    end
  end
end
