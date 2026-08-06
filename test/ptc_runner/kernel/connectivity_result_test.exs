defmodule PtcRunner.Kernel.ConnectivityResultTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ConnectivityResult

  @entry %{name: "alpha", destination: :workflow, index: 0, mode: :none, outcome: :skipped}

  test "an empty result is valid" do
    assert {:ok, []} = ConnectivityResult.new([])
  end

  test "only the closed outcome and mode vocabulary is accepted" do
    # The doctor plan settles rows from these values, so a result that could
    # carry an unknown outcome could smuggle one into a rendered row.
    assert ConnectivityResult.outcomes() == [:skipped]

    for forged <- [:reached, :pass, :failed, "skipped", nil] do
      assert {:error, :invalid_connectivity_result} =
               ConnectivityResult.new([%{@entry | outcome: forged}])
    end

    for mode <- [:none, :probe, :acquisition] do
      assert {:ok, _result} = ConnectivityResult.new([%{@entry | mode: mode}])
    end

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new([%{@entry | mode: :invented}])
  end

  test "an entry must carry exactly the occurrence identity fields" do
    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new([Map.delete(@entry, :index)])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new([Map.put(@entry, :extra, true)])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new([%{@entry | name: "Alpha"}])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new([%{@entry | destination: :elsewhere}])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new([%{@entry | index: -1}])
  end

  test "entries stay in declaration order and no site repeats" do
    workflow = @entry
    mission = %{@entry | destination: :mission, index: 0}

    assert {:ok, _result} = ConnectivityResult.new([workflow, mission])

    # Mission before workflow is not the order occurrences were declared in, so
    # a result in that order no longer says which one was reached first.
    assert {:error, :invalid_connectivity_result} = ConnectivityResult.new([mission, workflow])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new([%{@entry | index: 1}, @entry])

    assert {:error, :invalid_connectivity_result} =
             ConnectivityResult.new([@entry, %{@entry | name: "beta"}])
  end

  test "a result that is not a list of entries is refused" do
    for forged <- [nil, %{}, "[]", [nil], [@entry, :entry]] do
      assert {:error, :invalid_connectivity_result} = ConnectivityResult.new(forged)
      refute ConnectivityResult.valid?(forged)
    end
  end

  test "coverage is checked against a prepared run rather than assumed" do
    refute ConnectivityResult.covers?([@entry], nil)
    refute ConnectivityResult.covers?(:not_a_result, nil)
  end
end
