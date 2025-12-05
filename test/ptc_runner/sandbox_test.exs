defmodule PtcRunner.SandboxTest do
  use ExUnit.Case, async: true

  describe "Sandbox.execute/2 - with default options" do
    test "executes program with default options" do
      ast = %{"op" => "literal", "value" => 42}
      context = PtcRunner.Context.new()

      {:ok, result, metrics} = PtcRunner.Sandbox.execute(ast, context)

      assert result == 42
      assert is_map(metrics)
      assert metrics.duration_ms >= 0
      assert metrics.memory_bytes >= 0
    end

    test "executes program with empty ast and default options" do
      ast = %{}
      context = PtcRunner.Context.new()

      {:error, _} = PtcRunner.Sandbox.execute(ast, context)
    end

    test "executes program with context variables using default options" do
      ast = %{"op" => "load", "name" => "x"}
      context = PtcRunner.Context.new(%{"x" => "hello"})

      {:ok, result, _metrics} = PtcRunner.Sandbox.execute(ast, context)

      assert result == "hello"
    end
  end

  describe "Sandbox.execute/3 - with explicit options" do
    test "executes with custom timeout option" do
      ast = %{"op" => "literal", "value" => 100}
      context = PtcRunner.Context.new()
      opts = [timeout_ms: 5000]

      {:ok, result, _metrics} = PtcRunner.Sandbox.execute(ast, context, opts)

      assert result == 100
    end

    test "executes with custom memory limit option" do
      ast = %{"op" => "literal", "value" => "data"}
      context = PtcRunner.Context.new()
      opts = [max_memory_mb: 50]

      {:ok, result, _metrics} = PtcRunner.Sandbox.execute(ast, context, opts)

      assert result == "data"
    end

    test "executes with multiple custom options" do
      ast = %{"op" => "literal", "value" => [1, 2, 3]}
      context = PtcRunner.Context.new()
      opts = [timeout_ms: 3000, max_memory_mb: 20]

      {:ok, result, _metrics} = PtcRunner.Sandbox.execute(ast, context, opts)

      assert result == [1, 2, 3]
    end
  end

  describe "Sandbox.execute/3 - error handling" do
    test "returns error for invalid ast" do
      ast = %{"op" => "invalid_op"}
      context = PtcRunner.Context.new()
      opts = [timeout_ms: 1000]

      {:error, _reason} = PtcRunner.Sandbox.execute(ast, context, opts)
    end

    test "returns error when operation is unknown" do
      ast = %{"op" => "unknown_operation"}
      context = PtcRunner.Context.new()

      {:error, _reason} = PtcRunner.Sandbox.execute(ast, context)
    end

    test "returns error when execution fails" do
      ast = "not a map"
      context = PtcRunner.Context.new()

      {:error, {:execution_error, _msg}} = PtcRunner.Sandbox.execute(ast, context)
    end
  end

  describe "Sandbox metrics" do
    test "metrics include duration_ms" do
      ast = %{"op" => "literal", "value" => 1}
      context = PtcRunner.Context.new()

      {:ok, _result, metrics} = PtcRunner.Sandbox.execute(ast, context)

      assert is_integer(metrics.duration_ms)
      assert metrics.duration_ms >= 0
    end

    test "metrics include memory_bytes" do
      ast = %{"op" => "literal", "value" => 2}
      context = PtcRunner.Context.new()

      {:ok, _result, metrics} = PtcRunner.Sandbox.execute(ast, context)

      assert is_integer(metrics.memory_bytes)
      assert metrics.memory_bytes >= 0
    end

    test "metrics are accurate for simple operations" do
      ast = %{"op" => "literal", "value" => 42}
      context = PtcRunner.Context.new()

      {:ok, result, metrics} = PtcRunner.Sandbox.execute(ast, context)

      assert result == 42
      assert metrics.duration_ms >= 0
      assert metrics.memory_bytes > 0
    end
  end

  describe "Sandbox.execute/3 - process isolation" do
    test "executes in isolation without affecting outer process" do
      ast = %{"op" => "literal", "value" => "isolated"}
      context = PtcRunner.Context.new()

      {:ok, result, _metrics} = PtcRunner.Sandbox.execute(ast, context)

      assert result == "isolated"
      # Outer process is unaffected
      assert Process.alive?(self())
    end

    test "executes multiple times independently" do
      context = PtcRunner.Context.new()

      ast1 = %{"op" => "literal", "value" => 1}
      {:ok, result1, _} = PtcRunner.Sandbox.execute(ast1, context)

      ast2 = %{"op" => "literal", "value" => 2}
      {:ok, result2, _} = PtcRunner.Sandbox.execute(ast2, context)

      assert result1 == 1
      assert result2 == 2
    end
  end
end
