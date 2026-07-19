defmodule PtcRunner.Lisp.Eval.EffectsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Eval.Effects

  test "empty is the merge identity" do
    effects = %Effects{
      tool_calls: [%{id: 1}],
      pmap_calls: [%{id: 2}],
      prints: ["new"],
      prelude_call_counts: %{"api/run" => 2},
      tool_cache: %{key: :value}
    }

    assert Effects.merge(effects, Effects.empty()) == effects
    assert Effects.merge(Effects.empty(), effects) == effects
  end

  test "merge is associative with newest cache precedence" do
    oldest = %Effects{prints: ["old"], tool_cache: %{shared: :old, old: true}}
    middle = %Effects{prints: ["middle"], tool_cache: %{shared: :middle}}
    newest = %Effects{prints: ["new"], tool_cache: %{shared: :new}}

    left = Effects.merge(newest, Effects.merge(middle, oldest))
    right = Effects.merge(Effects.merge(newest, middle), oldest)

    assert left == right
    assert left.prints == ["new", "middle", "old"]
    assert left.tool_cache == %{shared: :new, old: true}
  end

  test "delta removes the cumulative baseline and retains cache overwrites" do
    baseline = %Effects{
      tool_calls: [%{id: :old}],
      prints: ["old"],
      prelude_call_counts: %{"api/run" => 1},
      tool_cache: %{same: 1, overwritten: 1}
    }

    cumulative = %Effects{
      tool_calls: [%{id: :new}, %{id: :old}],
      prints: ["new", "old"],
      prelude_call_counts: %{"api/run" => 3},
      tool_cache: %{same: 1, overwritten: 2, added: 3}
    }

    assert Effects.delta(cumulative, baseline) == %Effects{
             tool_calls: [%{id: :new}],
             prints: ["new"],
             prelude_call_counts: %{"api/run" => 2},
             tool_cache: %{overwritten: 2, added: 3}
           }
  end

  test "delta retains exact numeric overwrites nested in cache entries" do
    baseline = %Effects{tool_cache: %{key: %{result: %{value: 1}}}}
    cumulative = %Effects{tool_cache: %{key: %{result: %{value: 1.0}}}}

    delta = Effects.delta(cumulative, baseline)

    assert delta.tool_cache == %{key: %{result: %{value: 1.0}}}
    assert Effects.merge(delta, baseline).tool_cache === cumulative.tool_cache
  end

  test "ordered merge reports earlier deltas first and lets later cache writes win" do
    effects =
      Effects.merge_ordered([
        %Effects{prints: ["0"], tool_cache: %{shared: 0}},
        %Effects{prints: ["1"], tool_cache: %{shared: 1}},
        %Effects{prints: ["2"], tool_cache: %{shared: 2}}
      ])

    assert Effects.chronological(effects).prints == ["0", "1", "2"]
    assert effects.tool_cache.shared == 2
  end
end
