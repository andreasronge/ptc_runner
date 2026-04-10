defmodule PtcRunner.Folding.OracleTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.Oracle

  @context %{"products" => [%{"price" => 100}, %{"price" => 600}, %{"price" => 300}]}
  @task %{source: "(count data/products)", output_type: :integer}

  test "evaluate returns correct answer on base context" do
    assert {:ok, 3} = Oracle.evaluate(@task, @context)
  end

  test "evaluate returns correct answer on modified context" do
    modified = %{"products" => [%{"price" => 100}]}
    assert {:ok, 1} = Oracle.evaluate(@task, modified)
  end

  test "evaluate returns error for bad source" do
    task = %{source: "(bad-fn data/products)", output_type: :integer}
    assert {:error, _} = Oracle.evaluate(task, @context)
  end

  test "score exact match returns 1.0" do
    assert Oracle.score(3, 3, :integer) == 1.0
  end

  test "score nil returns 0.0" do
    assert Oracle.score(nil, 3, :integer) == 0.0
  end

  test "score close integer gives partial credit" do
    score = Oracle.score(4, 3, :integer)
    assert score > 0.0 and score < 1.0
  end

  test "score wrong type gives minimal credit" do
    score = Oracle.score("hello", 3, :integer)
    assert score == 0.05
  end

  test "score numeric proximity" do
    close = Oracle.score(290, 300, :integer)
    far = Oracle.score(100, 300, :integer)
    assert close > far
  end
end
