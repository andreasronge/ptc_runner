defmodule PtcRunner.SandboxTest do
  use ExUnit.Case, async: true

  # Simple eval_fn that returns the AST value directly
  defp simple_eval(value, _context), do: {:ok, value, %{}}

  defp eval_opts, do: [eval_fn: &simple_eval/2]

  describe "Sandbox.execute/3 - basic execution" do
    test "executes program with eval_fn" do
      context = PtcRunner.Context.new()

      {:ok, result, metrics, _memory} =
        PtcRunner.Sandbox.execute(42, context, eval_opts())

      assert result == 42
      assert is_map(metrics)
      assert metrics.duration_ms >= 0
      assert metrics.memory_bytes >= 0
    end

    test "executes with empty map" do
      context = PtcRunner.Context.new()

      {:ok, result, _metrics, _memory} =
        PtcRunner.Sandbox.execute(%{}, context, eval_opts())

      assert result == %{}
    end

    test "executes with list value" do
      context = PtcRunner.Context.new()

      {:ok, result, _metrics, _memory} =
        PtcRunner.Sandbox.execute([1, 2, 3], context, eval_opts())

      assert result == [1, 2, 3]
    end
  end

  describe "Sandbox.execute/3 - with explicit options" do
    test "executes with custom timeout option" do
      context = PtcRunner.Context.new()
      opts = [timeout_ms: 5000] ++ eval_opts()

      {:ok, result, _metrics, _memory} = PtcRunner.Sandbox.execute(100, context, opts)

      assert result == 100
    end

    test "executes with custom memory limit option" do
      context = PtcRunner.Context.new()
      opts = [max_memory_mb: 50] ++ eval_opts()

      {:ok, result, _metrics, _memory} = PtcRunner.Sandbox.execute("data", context, opts)

      assert result == "data"
    end

    test "executes with multiple custom options" do
      context = PtcRunner.Context.new()
      opts = [timeout_ms: 3000, max_memory_mb: 20] ++ eval_opts()

      {:ok, result, _metrics, _memory} = PtcRunner.Sandbox.execute([1, 2, 3], context, opts)

      assert result == [1, 2, 3]
    end
  end

  describe "Sandbox.execute/3 - error handling" do
    test "returns error when eval_fn returns error" do
      error_eval = fn _ast, _ctx -> {:error, {:runtime_error, "boom"}} end
      context = PtcRunner.Context.new()

      {:error, {:runtime_error, "boom"}} =
        PtcRunner.Sandbox.execute(:anything, context, eval_fn: error_eval)
    end

    test "returns error when execution crashes" do
      crash_eval = fn _ast, _ctx -> raise "crash" end
      context = PtcRunner.Context.new()

      {:error, {:execution_error, _msg}} =
        PtcRunner.Sandbox.execute(:anything, context, eval_fn: crash_eval)
    end
  end

  describe "Sandbox metrics" do
    test "metrics include duration_ms" do
      context = PtcRunner.Context.new()

      {:ok, _result, metrics, _memory} =
        PtcRunner.Sandbox.execute(1, context, eval_opts())

      assert is_integer(metrics.duration_ms)
      assert metrics.duration_ms >= 0
    end

    test "metrics include memory_bytes" do
      context = PtcRunner.Context.new()

      {:ok, _result, metrics, _memory} =
        PtcRunner.Sandbox.execute(2, context, eval_opts())

      assert is_integer(metrics.memory_bytes)
      assert metrics.memory_bytes >= 0
    end

    test "metrics are accurate for simple operations" do
      context = PtcRunner.Context.new()

      {:ok, result, metrics, _memory} =
        PtcRunner.Sandbox.execute(42, context, eval_opts())

      assert result == 42
      assert metrics.duration_ms >= 0
      assert metrics.memory_bytes > 0
    end
  end

  describe "Sandbox.execute/3 - process isolation" do
    test "executes in isolation without affecting outer process" do
      context = PtcRunner.Context.new()

      {:ok, result, _metrics, _memory} =
        PtcRunner.Sandbox.execute("isolated", context, eval_opts())

      assert result == "isolated"
      # Outer process is unaffected
      assert Process.alive?(self())
    end

    test "executes multiple times independently" do
      context = PtcRunner.Context.new()

      {:ok, result1, _, _} = PtcRunner.Sandbox.execute(1, context, eval_opts())
      {:ok, result2, _, _} = PtcRunner.Sandbox.execute(2, context, eval_opts())

      assert result1 == 1
      assert result2 == 2
    end
  end
end
