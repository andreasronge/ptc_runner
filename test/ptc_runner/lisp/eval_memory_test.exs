defmodule PtcRunner.Lisp.EvalMemoryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Eval

  describe "memory threading" do
    test "memory is threaded through literals" do
      memory = %{count: 5}
      {:ok, value, new_memory} = Eval.eval(42, %{}, memory, %{}, &dummy_tool/2)

      assert value == 42
      assert new_memory == memory
    end

    test "memory is threaded through vector evaluation" do
      memory = %{count: 5}

      {:ok, [1, 2, 3], new_memory} =
        Eval.eval({:vector, [1, 2, 3]}, %{}, memory, %{}, &dummy_tool/2)

      assert new_memory == memory
    end

    test "memory is threaded through map evaluation" do
      memory = %{count: 5}

      {:ok, %{a: 1}, new_memory} =
        Eval.eval({:map, [{{:keyword, :a}, 1}]}, %{}, memory, %{}, &dummy_tool/2)

      assert new_memory == memory
    end
  end

  defp dummy_tool(_name, _args), do: :ok
end
