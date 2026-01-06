defmodule PtcRunner.Lisp.VectorKeyTest do
  use ExUnit.Case
  alias PtcRunner.Lisp.Runtime

  test "avg-by with vector path" do
    data = [%{salary: 100}, %{salary: 200}]
    assert Runtime.avg_by([:salary], data) == 150.0
  end

  test "avg_by with nil data" do
    assert Runtime.avg_by([:salary], nil) == nil
  end

  test "pluck with vector path" do
    data = [%{salary: 100}, %{salary: 200}]
    assert Runtime.pluck([:salary], data) == [100, 200]
  end

  test "pluck with empty path returns items" do
    data = [%{salary: 100}, %{salary: 200}]
    assert Runtime.pluck([], data) == data
  end

  test "nested vector path for pluck" do
    data = [%{address: %{city: "Oslo"}}, %{address: %{city: "Bergen"}}]
    assert Runtime.pluck([:address, :city], data) == ["Oslo", "Bergen"]
  end

  test "mixed type path for pluck" do
    data = [%{"address" => %{city: "Oslo"}}, %{"address" => %{city: "Bergen"}}]
    assert Runtime.pluck(["address", :city], data) == ["Oslo", "Bergen"]
  end

  test "sum_by with vector path" do
    data = [%{amount: 100}, %{amount: 200}, %{other: 50}]
    assert Runtime.sum_by([:amount], data) == 300
  end

  test "min_by with vector path" do
    data = [%{val: 30}, %{val: 10}, %{val: 20}]
    assert Runtime.min_by([:val], data) == %{val: 10}
  end

  test "max_by with vector path" do
    data = [%{val: 30}, %{val: 10}, %{val: 20}]
    assert Runtime.max_by([:val], data) == %{val: 30}
  end

  test "group_by with vector path" do
    data = [%{cat: "A", v: 1}, %{cat: "B", v: 2}, %{cat: "A", v: 3}]
    result = Runtime.group_by([:cat], data)
    assert result["A"] == [%{cat: "A", v: 1}, %{cat: "A", v: 3}]
    assert result["B"] == [%{cat: "B", v: 2}]
  end

  test "sort_by/3 with vector path" do
    data = [%{age: 30}, %{age: 20}, %{age: 25}]
    # Descending sort
    assert Runtime.sort_by([:age], &>=/2, data) == [%{age: 30}, %{age: 25}, %{age: 20}]
  end

  test "filter with vector path errors" do
    data = [%{status: "active"}]

    assert_raise RuntimeError,
                 ~r/expected predicate, got vector \[:status\] - use :status instead/,
                 fn ->
                   Runtime.filter([:status], data)
                 end
  end

  test "filter with multi-element vector path errors" do
    data = [%{address: %{city: "Oslo"}}]

    assert_raise RuntimeError,
                 ~r/expected predicate, got path \[:address, :city\] - paths require a function or data-extraction variant/,
                 fn ->
                   Runtime.filter([:address, :city], data)
                 end
  end

  test "map with vector path errors" do
    assert_raise RuntimeError,
                 ~r/expected function or key, got vector \[:status\] - use :status instead/,
                 fn ->
                   Runtime.map([:status], [%{status: 1}])
                 end
  end

  test "remove with vector path errors" do
    assert_raise RuntimeError,
                 ~r/expected predicate, got vector \[:status\] - use :status instead/,
                 fn ->
                   Runtime.remove([:status], [%{status: true}])
                 end
  end

  test "find with vector path errors" do
    assert_raise RuntimeError,
                 ~r/expected predicate, got vector \[:status\] - use :status instead/,
                 fn ->
                   Runtime.find([:status], [%{status: true}])
                 end
  end

  test "mapv with vector path errors" do
    assert_raise RuntimeError,
                 ~r/expected function or key, got vector \[:status\] - use :status instead/,
                 fn ->
                   Runtime.mapv([:status], [%{status: 1}])
                 end
  end

  test "drop_while with vector path errors" do
    assert_raise RuntimeError,
                 ~r/expected predicate, got vector \[:status\] - use :status instead/,
                 fn ->
                   Runtime.drop_while([:status], [%{status: true}])
                 end
  end

  test "some with vector path errors" do
    assert_raise RuntimeError,
                 ~r/expected predicate, got vector \[:status\] - use :status instead/,
                 fn ->
                   Runtime.some([:status], [%{status: true}])
                 end
  end

  test "not_any? with vector path errors" do
    assert_raise RuntimeError,
                 ~r/expected predicate, got vector \[:status\] - use :status instead/,
                 fn ->
                   Runtime.not_any?([:status], [%{status: true}])
                 end
  end

  test "take_while with vector path errors" do
    assert_raise RuntimeError,
                 ~r/expected predicate, got vector \[:status\] - use :status instead/,
                 fn ->
                   Runtime.take_while([:status], [%{status: true}])
                 end
  end

  test "every? with vector path errors" do
    assert_raise RuntimeError,
                 ~r/expected predicate, got vector \[:status\] - use :status instead/,
                 fn ->
                   Runtime.every?([:status], [%{status: true}])
                 end
  end
end
