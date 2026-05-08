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
    test "emits :start and :stop with the spec'd metadata and measurement keys" do
      assert {:ok, _step} = Lisp.run("(+ 1 2)")

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], start_meas, start_meta}
      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :stop], stop_meas, stop_meta}

      # :start measurements are :telemetry.span defaults
      assert Map.has_key?(start_meas, :system_time)
      assert Map.has_key?(start_meas, :monotonic_time)

      # :start metadata: caller, program_bytes, signature_supplied?
      assert start_meta.caller == :in_process_v1
      assert start_meta.program_bytes == byte_size("(+ 1 2)")
      assert start_meta.signature_supplied? == false

      # :stop measurements: duration plus our additions
      assert Map.has_key?(stop_meas, :duration)
      assert is_integer(Map.fetch!(stop_meas, :result_bytes))
      assert Map.fetch!(stop_meas, :result_bytes) > 0
      assert Map.fetch!(stop_meas, :prints_count) == 0

      # :stop metadata mirrors :start metadata
      assert stop_meta.caller == :in_process_v1
      assert stop_meta.program_bytes == byte_size("(+ 1 2)")
      assert stop_meta.signature_supplied? == false
    end

    test "default :caller is :in_process_v1" do
      assert {:ok, _} = Lisp.run("(+ 1 2)")

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _,
                      %{caller: :in_process_v1}}

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :stop], _,
                      %{caller: :in_process_v1}}
    end

    test ":caller option propagates to :start and :stop" do
      assert {:ok, _} = Lisp.run("(+ 1 2)", caller: :mcp)
      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _, %{caller: :mcp}}
      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :stop], _, %{caller: :mcp}}
    end

    test ":caller :text_mode is accepted" do
      assert {:ok, _} = Lisp.run("(+ 1 2)", caller: :text_mode)

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _,
                      %{caller: :text_mode}}
    end

    test ":profile defaults to nil and propagates to :start and :stop (Phase 0 §11.5)" do
      assert {:ok, _} = Lisp.run("(+ 1 2)")

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _, %{profile: nil}}

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :stop], _, %{profile: nil}}
    end

    test ":profile :mcp_no_tools propagates (Phase 0 §11.5)" do
      assert {:ok, _} = Lisp.run("(+ 1 2)", caller: :mcp, profile: :mcp_no_tools)

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _,
                      %{caller: :mcp, profile: :mcp_no_tools}}

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :stop], _,
                      %{caller: :mcp, profile: :mcp_no_tools}}
    end

    test "out-of-set :profile raises ArgumentError (closed set)" do
      assert_raise ArgumentError, fn ->
        Lisp.run("(+ 1 2)", profile: :bogus)
      end
    end

    test ":profile accepts :mcp_aggregator, :in_process_v1, :text_mode" do
      for prof <- [:mcp_aggregator, :in_process_v1, :text_mode] do
        assert {:ok, _} = Lisp.run("(+ 1 2)", profile: prof)
        assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _, %{profile: ^prof}}
      end
    end

    test "out-of-set :caller raises ArgumentError naming the bad atom and the closed set" do
      assert_raise ArgumentError, fn -> Lisp.run("(+ 1 2)", caller: :bogus) end

      try do
        Lisp.run("(+ 1 2)", caller: :bogus)
      rescue
        e in ArgumentError ->
          assert e.message =~ ":bogus"
          assert e.message =~ ":in_process_v1"
          assert e.message =~ ":text_mode"
          assert e.message =~ ":mcp"
      end
    end

    test "ArgumentError fires before any telemetry event is emitted" do
      # Drain any prior messages
      flush_telemetry()

      assert_raise ArgumentError, fn -> Lisp.run("(+ 1 2)", caller: :bogus) end
      refute_received {:telemetry, [:ptc_runner, :lisp, :execute, _], _, _}
    end

    test "signature_supplied? is true when :signature opt is given" do
      sig = "() -> :int"
      assert {:ok, _} = Lisp.run("(+ 1 2)", signature: sig)

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _,
                      %{signature_supplied?: true}}

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :stop], _,
                      %{signature_supplied?: true}}
    end

    test "errors returned via {:error, Step.t()} still emit :stop (not :exception)" do
      # An undefined variable produces {:error, step}, not a raise.
      # The span fn returns normally, so :stop fires.
      assert {:error, _} = Lisp.run("(+ undefined-var 1)", caller: :mcp)
      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _, %{caller: :mcp}}
      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :stop], _, %{caller: :mcp}}
      refute_received {:telemetry, [:ptc_runner, :lisp, :execute, :exception], _, _}
    end

    test ":exception event fires when run/2 itself raises and carries caller + kind/reason/stacktrace" do
      # An invalid (non-string, non-keyword) opts value forces a raise inside
      # the span body. Use a tools value that fails Tool.new for a non-binary
      # name? Easier: pass non-string source — Parser will likely raise.
      # Cleanest path: pass :tools as a non-enumerable to force a runtime crash
      # inside do_run.
      #
      # We use a custom telemetry handler that raises to verify our :exception
      # path — but raising inside a handler doesn't exercise the span exception
      # path (telemetry catches handler errors). Instead, directly cause a
      # runtime failure inside the span by passing a source that's not a binary.
      assert_raise FunctionClauseError, fn ->
        Lisp.run(:not_a_binary, caller: :text_mode)
      end

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :start], _,
                      %{caller: :text_mode}}

      assert_receive {:telemetry, [:ptc_runner, :lisp, :execute, :exception], exc_meas, exc_meta}

      assert Map.has_key?(exc_meas, :duration)
      assert exc_meta.caller == :text_mode
      assert Map.has_key?(exc_meta, :kind)
      assert Map.has_key?(exc_meta, :reason)
      assert Map.has_key?(exc_meta, :stacktrace)
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
