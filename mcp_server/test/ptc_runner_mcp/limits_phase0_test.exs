defmodule PtcRunnerMcp.LimitsPhase0Test do
  @moduledoc """
  Phase 0 getters added to `Limits` per §11.6: `program_timeout_ms` and
  `program_memory_limit_bytes` (defaults 1000 / 10 * 1024 * 1024 — the
  v1 PTC-Lisp sandbox defaults).

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §11.6, §9.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Limits

  setup do
    # These tests mutate the persistent_term limits map. Reset to
    # defaults after each test so we don't leak state.
    on_exit(fn -> Limits.set(Limits.defaults()) end)
    :ok
  end

  test "defaults match the v1 PTC-Lisp sandbox (1 s / 10 MB)" do
    Limits.set(Limits.defaults())
    assert Limits.program_timeout_ms() == 1000
    assert Limits.program_memory_limit_bytes() == 10 * 1024 * 1024
  end

  test "Limits.set/1 honors program_timeout_ms override" do
    Limits.set(Map.put(Limits.defaults(), :program_timeout_ms, 5000))
    assert Limits.program_timeout_ms() == 5000
  end

  test "Limits.set/1 honors program_memory_limit_bytes override" do
    big = 50 * 1024 * 1024
    Limits.set(Map.put(Limits.defaults(), :program_memory_limit_bytes, big))
    assert Limits.program_memory_limit_bytes() == big
  end
end
