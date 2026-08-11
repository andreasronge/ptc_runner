defmodule PtcRunner.Kernel.DeadlineTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Deadline

  test "deadlines share an exact caller-provided anchor" do
    anchor_ms = System.monotonic_time(:millisecond)

    first = Deadline.new(100, anchor_ms)
    second = Deadline.new(250, anchor_ms)

    assert Deadline.expires_at(first) == anchor_ms + 100
    assert Deadline.expires_at(second) == anchor_ms + 250
    assert Deadline.valid?(first)
    assert Deadline.valid?(second)
  end

  test "remaining time is non-negative and expiry includes the exact cutoff" do
    deadline = Deadline.new(10, 100)

    assert Deadline.remaining(deadline, 99) == 11
    assert Deadline.remaining(deadline, 109) == 1
    assert Deadline.remaining(deadline, 110) == 0
    assert Deadline.remaining(deadline, 111) == 0

    refute Deadline.expired?(deadline, 109)
    assert Deadline.expired?(deadline, 110)
    assert Deadline.expired?(deadline, 111)
  end

  test "constructs an exact existing cutoff" do
    deadline = Deadline.from_expires_at(110)

    assert Deadline.expires_at(deadline) == 110
    assert Deadline.remaining(deadline, 99) == 11
  end

  test "earliest preserves an existing deadline and never extends it" do
    anchor_ms = System.monotonic_time(:millisecond)
    first = Deadline.new(100, anchor_ms)
    second = Deadline.new(200, anchor_ms)
    tied = Deadline.new(100, anchor_ms)

    assert Deadline.earliest(first, second) === first
    assert Deadline.earliest(second, first) === first
    assert Deadline.earliest(first, tied) === first
  end

  test "non-positive timeouts have no constructor clause" do
    assert_raise FunctionClauseError, fn -> Deadline.new(0) end
    assert_raise FunctionClauseError, fn -> Deadline.new(-1, 0) end
  end

  test "terminalization floors an expired cutoff and preserves a longer live one" do
    now = System.monotonic_time(:millisecond)

    floored = Deadline.terminalization(now - 60_000)
    assert Deadline.expires_at(floored) >= now + 4_000
    assert Deadline.expires_at(floored) <= now + 6_000

    distant = now + 60_000
    assert Deadline.expires_at(Deadline.terminalization(distant)) == distant
  end
end
