defmodule PtcRunner.SubAgent.CompactionTest do
  use ExUnit.Case, async: true

  doctest PtcRunner.SubAgent.Compaction

  alias PtcRunner.SubAgent.Compaction
  alias PtcRunner.SubAgent.Compaction.{Context, Trim}

  defp ctx(fields \\ []) do
    counter = Keyword.get(fields, :token_counter, &Compaction.default_token_counter/1)

    %Context{
      turn: Keyword.get(fields, :turn, 1),
      max_turns: Keyword.get(fields, :max_turns, 10),
      retry_phase?: Keyword.get(fields, :retry_phase?, false),
      memory: Keyword.get(fields, :memory, nil),
      token_counter: counter
    }
  end

  defp u(content), do: %{role: :user, content: content}
  defp a(content), do: %{role: :assistant, content: content}

  defp default_trim_opts(overrides) do
    Keyword.merge(Compaction.default_trim_opts(), overrides)
  end

  describe "normalize/1" do
    test "nil disables compaction" do
      assert Compaction.normalize(nil) == {:disabled, []}
    end

    test "false disables compaction" do
      assert Compaction.normalize(false) == {:disabled, []}
    end

    test "true selects :trim with defaults" do
      {:trim, opts} = Compaction.normalize(true)

      assert opts[:strategy] == :trim
      assert opts[:keep_recent_turns] == 3
      assert opts[:keep_initial_user] == true
      assert opts[:trigger] == [turns: 8]
      assert is_nil(opts[:token_counter])
    end

    test "keyword without strategy defaults to :trim and merges defaults" do
      {:trim, opts} = Compaction.normalize(keep_recent_turns: 5)

      assert opts[:strategy] == :trim
      assert opts[:keep_recent_turns] == 5
      # default carried through
      assert opts[:trigger] == [turns: 8]
      assert opts[:keep_initial_user] == true
    end

    test "keyword with explicit strategy: :trim is accepted" do
      {:trim, opts} = Compaction.normalize(strategy: :trim, trigger: [tokens: 5_000])

      assert opts[:strategy] == :trim
      assert opts[:trigger] == [tokens: 5_000]
    end

    test "rejects empty keyword list" do
      assert_raise ArgumentError, ~r/compaction: \[\] is invalid/, fn ->
        Compaction.normalize([])
      end
    end

    test "rejects unsupported strategy" do
      assert_raise ArgumentError, ~r/Phase 1 supports `strategy: :trim` only/, fn ->
        Compaction.normalize(strategy: :summarize)
      end

      assert_raise ArgumentError, ~r/Phase 1 supports/, fn ->
        Compaction.normalize(strategy: :last_n)
      end
    end

    test "rejects bare module atom" do
      assert_raise ArgumentError, ~r/Custom strategy modules are not supported/, fn ->
        Compaction.normalize(SomeStrategy)
      end
    end

    test "rejects {module, opts} tuple form" do
      assert_raise ArgumentError, ~r/Custom strategy modules/, fn ->
        Compaction.normalize({SomeStrategy, []})
      end
    end

    test "rejects unknown top-level keys (catches typos)" do
      assert_raise ArgumentError, ~r/Unknown compaction option\(s\): \[:keep_recent_turn\]/, fn ->
        Compaction.normalize(keep_recent_turn: 3)
      end
    end

    test "rejects keep_recent_turns < 1" do
      assert_raise ArgumentError, ~r/keep_recent_turns must be an integer >= 1/, fn ->
        Compaction.normalize(keep_recent_turns: 0)
      end

      assert_raise ArgumentError, ~r/keep_recent_turns must be an integer >= 1/, fn ->
        Compaction.normalize(keep_recent_turns: -1)
      end
    end

    test "rejects non-boolean keep_initial_user" do
      assert_raise ArgumentError, ~r/keep_initial_user must be a boolean/, fn ->
        Compaction.normalize(keep_initial_user: "yes")
      end
    end

    test "rejects empty trigger keyword" do
      assert_raise ArgumentError, ~r/trigger must specify at least one of/, fn ->
        Compaction.normalize(trigger: [])
      end
    end

    test "rejects unknown trigger keys" do
      assert_raise ArgumentError, ~r/Unknown trigger key\(s\): \[:minutes\]/, fn ->
        Compaction.normalize(trigger: [minutes: 5])
      end
    end

    test "rejects non-positive trigger[:turns]" do
      assert_raise ArgumentError, ~r/trigger\[:turns\] must be a positive integer/, fn ->
        Compaction.normalize(trigger: [turns: 0])
      end
    end

    test "rejects non-positive trigger[:tokens]" do
      assert_raise ArgumentError, ~r/trigger\[:tokens\] must be a positive integer/, fn ->
        Compaction.normalize(trigger: [tokens: -10])
      end
    end

    test "rejects trigger that isn't a list" do
      assert_raise ArgumentError, ~r/trigger must be a keyword list/, fn ->
        Compaction.normalize(trigger: :often)
      end
    end

    test "rejects token_counter with wrong arity" do
      assert_raise ArgumentError, ~r/token_counter must be a 1-arity function or nil/, fn ->
        Compaction.normalize(token_counter: fn _a, _b -> 0 end)
      end
    end

    test "accepts a valid token_counter function" do
      counter = fn s -> byte_size(s) end
      {:trim, opts} = Compaction.normalize(token_counter: counter)
      assert opts[:token_counter] == counter
    end

    test "rejects unsupported scalar configurations" do
      assert_raise ArgumentError, fn -> Compaction.normalize(123) end
      assert_raise ArgumentError, fn -> Compaction.normalize("trim") end
    end
  end

  describe "maybe_compact/3 — disabled" do
    test "passes through messages and returns :disabled" do
      msgs = [u("hi"), a("hello")]
      assert {:disabled, ^msgs} = Compaction.maybe_compact(msgs, ctx(), {:disabled, []})
    end
  end

  describe ":trim — does not trigger below threshold" do
    test "no triggers fired returns :not_triggered" do
      msgs =
        for i <- 1..6 do
          if rem(i, 2) == 1, do: u("u#{i}"), else: a("a#{i}")
        end

      {:trim, opts} = Compaction.normalize(true)

      assert {:not_triggered, ^msgs, stats} =
               Compaction.maybe_compact(msgs, ctx(turn: 3), {:trim, opts})

      assert stats == %{enabled: true, triggered: false, strategy: "trim"}
    end

    test "fewer messages than min_required returns :not_triggered even past turn threshold" do
      msgs = [u("only"), a("response")]
      {:trim, opts} = Compaction.normalize(true)

      assert {:not_triggered, ^msgs, _stats} =
               Compaction.maybe_compact(msgs, ctx(turn: 50), {:trim, opts})
    end
  end

  describe ":trim — triggers on turn pressure" do
    test "fires when ctx.turn > trigger[:turns]" do
      msgs =
        for i <- 1..12 do
          if rem(i, 2) == 1, do: u("u#{i}"), else: a("a#{i}")
        end

      {:trim, opts} =
        Compaction.normalize(trigger: [turns: 5], keep_recent_turns: 2, keep_initial_user: true)

      assert {trimmed, stats} = Compaction.maybe_compact(msgs, ctx(turn: 6), {:trim, opts})

      assert stats.triggered == true
      assert stats.reason == :turn_pressure
      assert stats.strategy == "trim"
      assert stats.messages_before == 12
      assert stats.kept_initial_user? == true
      assert stats.kept_recent_turns == 2
      # 1 initial user + 4 recent (2 turns * 2 messages)
      assert length(trimmed) == 5
      assert hd(trimmed) == u("u1")
    end

    test "does not fire when ctx.turn equals trigger[:turns]" do
      msgs =
        for i <- 1..12 do
          if rem(i, 2) == 1, do: u("u#{i}"), else: a("a#{i}")
        end

      {:trim, opts} = Compaction.normalize(trigger: [turns: 5], keep_recent_turns: 2)

      assert {:not_triggered, ^msgs, _} =
               Compaction.maybe_compact(msgs, ctx(turn: 5), {:trim, opts})
    end
  end

  describe ":trim — triggers on token pressure" do
    test "fires when total estimated tokens >= trigger[:tokens]" do
      msgs =
        for i <- 1..10 do
          # 100 chars => 25 tokens each at default counter
          content = String.duplicate("x", 100)
          if rem(i, 2) == 1, do: u(content), else: a(content)
        end

      {:trim, opts} =
        Compaction.normalize(
          trigger: [tokens: 200],
          keep_recent_turns: 2,
          keep_initial_user: true
        )

      assert {trimmed, stats} = Compaction.maybe_compact(msgs, ctx(turn: 1), {:trim, opts})

      assert stats.triggered == true
      assert stats.reason == :token_pressure
      assert stats.estimated_tokens_before == 250
      assert stats.estimated_tokens_after < stats.estimated_tokens_before
      assert length(trimmed) < length(msgs)
    end

    test "either trigger fires (turn or token, OR semantics)" do
      content = String.duplicate("z", 40)

      msgs =
        for i <- 1..10, do: if(rem(i, 2) == 1, do: u(content), else: a(content))

      # turn does NOT fire (turn=1, threshold 100). tokens fires (10*10=100 >= 50).
      {:trim, opts} =
        Compaction.normalize(trigger: [turns: 100, tokens: 50], keep_recent_turns: 2)

      assert {_trimmed, stats} = Compaction.maybe_compact(msgs, ctx(turn: 1), {:trim, opts})
      assert stats.reason == :token_pressure
    end
  end

  describe ":trim — keep_initial_user behavior" do
    test "keeps the first :user message when keep_initial_user: true" do
      msgs = [u("first"), a("a1"), u("u2"), a("a2"), u("u3"), a("a3"), u("u4"), a("a4")]

      opts = default_trim_opts(trigger: [turns: 1], keep_recent_turns: 2, keep_initial_user: true)

      assert {trimmed, stats} = Trim.run(msgs, ctx(turn: 5), opts)
      assert hd(trimmed) == u("first")
      assert stats.kept_initial_user? == true
    end

    test "skips initial user when first message isn't :user" do
      # Pathological but documented: head is assistant.
      msgs = [a("a0"), u("u1"), a("a1"), u("u2"), a("a2"), u("u3"), a("a3"), u("u4")]

      opts = default_trim_opts(trigger: [turns: 1], keep_recent_turns: 2, keep_initial_user: true)

      assert {trimmed, stats} = Trim.run(msgs, ctx(turn: 5), opts)
      assert stats.kept_initial_user? == false
      # No leading :assistant
      refute match?([%{role: :assistant} | _], trimmed)
    end

    test "drops initial user when keep_initial_user: false" do
      msgs = [u("first"), a("a1"), u("u2"), a("a2"), u("u3"), a("a3"), u("u4"), a("a4")]

      opts =
        default_trim_opts(trigger: [turns: 1], keep_recent_turns: 2, keep_initial_user: false)

      assert {trimmed, stats} = Trim.run(msgs, ctx(turn: 5), opts)
      assert stats.kept_initial_user? == false
      # The first message of trimmed should not be u("first")
      refute hd(trimmed) == u("first")
      # But should still be :user (no leading :assistant)
      assert hd(trimmed).role == :user
    end
  end

  describe ":trim — never produces an assistant-leading recent slice" do
    test "drops one more message when slicing would start with :assistant" do
      # 4 turn pairs: keep_recent_turns=2 takes 4 trailing messages.
      # Without correction, recent = [a1, u2, a2, u3] starts with :assistant.
      msgs = [u("u0"), a("a0"), u("u1"), a("a1"), u("u2"), a("a2"), u("u3")]

      opts = default_trim_opts(trigger: [turns: 1], keep_recent_turns: 2, keep_initial_user: true)

      assert {trimmed, _stats} = Trim.run(msgs, ctx(turn: 5), opts)

      # Result is initial user + recent slice. Both must be :user-led.
      assert hd(trimmed).role == :user
      # Recent slice (everything after the kept first message) starts with :user too.
      [_first | rest] = trimmed
      assert hd(rest).role == :user
    end
  end

  describe ":trim — over_budget? flag" do
    test "true when a single retained message exceeds tokens budget" do
      huge = String.duplicate("y", 4_000)

      msgs = [
        u("init"),
        a("a1"),
        u("u2"),
        a("a2"),
        u("u3"),
        a("a3"),
        u(huge),
        a("final")
      ]

      opts =
        default_trim_opts(
          trigger: [tokens: 100],
          keep_recent_turns: 2,
          keep_initial_user: true
        )

      assert {_trimmed, stats} = Trim.run(msgs, ctx(turn: 1), opts)
      assert stats.triggered == true
      assert stats.over_budget? == true
    end

    test "false when no single message exceeds the tokens budget" do
      msgs =
        for i <- 1..12, do: if(rem(i, 2) == 1, do: u("u#{i}"), else: a("a#{i}"))

      opts =
        default_trim_opts(
          trigger: [turns: 5],
          keep_recent_turns: 2,
          keep_initial_user: true
        )

      assert {_trimmed, stats} = Trim.run(msgs, ctx(turn: 6), opts)
      assert stats.over_budget? == false
    end
  end

  describe ":trim — idempotence" do
    test "re-running on already trimmed history produces the same output" do
      msgs =
        for i <- 1..14, do: if(rem(i, 2) == 1, do: u("u#{i}"), else: a("a#{i}"))

      {:trim, opts} =
        Compaction.normalize(trigger: [turns: 3], keep_recent_turns: 3, keep_initial_user: true)

      {trimmed_1, stats_1} = Compaction.maybe_compact(msgs, ctx(turn: 7), {:trim, opts})

      # Run again on trimmed output. Pressure heuristics may or may not fire on
      # the smaller list; idempotence means the message list is the same shape.
      result_2 = Compaction.maybe_compact(trimmed_1, ctx(turn: 7), {:trim, opts})

      trimmed_2 =
        case result_2 do
          {:not_triggered, msgs2, _} -> msgs2
          {msgs2, _} -> msgs2
        end

      assert trimmed_1 == trimmed_2
      assert stats_1.triggered == true
    end
  end

  describe "build_context/2" do
    test "uses default token counter when none provided" do
      built = Compaction.build_context([turn: 2, max_turns: 10], [])
      assert built.token_counter.("0123456789") == 2
    end

    test "uses override token counter when provided" do
      counter = fn s -> byte_size(s) * 7 end
      built = Compaction.build_context([turn: 2, max_turns: 10], token_counter: counter)
      assert built.token_counter.("ab") == 14
    end

    test "carries retry_phase? and memory" do
      built =
        Compaction.build_context(
          [turn: 4, max_turns: 12, retry_phase?: true, memory: %{foo: 1}],
          []
        )

      assert built.retry_phase? == true
      assert built.memory == %{foo: 1}
      assert built.turn == 4
      assert built.max_turns == 12
    end
  end
end
