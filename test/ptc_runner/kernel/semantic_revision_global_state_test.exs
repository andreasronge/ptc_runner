defmodule PtcRunner.Kernel.SemanticRevisionGlobalStateTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.SemanticRevision
  alias PtcRunner.Lisp.Eval.Context

  test "a cache entry from an earlier module build cannot supply the current revision" do
    legacy_key = {SemanticRevision, :current}
    previous = :persistent_term.get(legacy_key, :missing)
    stale = "sem1-" <> String.duplicate("0", 64)

    on_exit(fn ->
      case previous do
        :missing -> :persistent_term.erase(legacy_key)
        value -> :persistent_term.put(legacy_key, value)
      end
    end)

    :persistent_term.put(legacy_key, stale)
    refute SemanticRevision.current() == stale
  end

  test "the scheduler-derived compiled default participates in semantic identity" do
    original = :erlang.system_info(:schedulers_online)
    total = :erlang.system_info(:schedulers)
    compiled_default = Context.default_pmap_max_concurrency()
    before_revision = SemanticRevision.current()

    if total > 1 do
      alternate = if original > 1, do: original - 1, else: original + 1
      on_exit(fn -> :erlang.system_flag(:schedulers_online, original) end)
      :erlang.system_flag(:schedulers_online, alternate)
    end

    context = Context.new(%{}, %{}, %{}, fn _name, _args, _meta -> nil end, [])

    assert context.pmap_max_concurrency == compiled_default
    assert SemanticRevision.current() == before_revision

    build = %{"source" => "same"}

    refute SemanticRevision.revision_for(
             build,
             %{"compiled_pmap_max_concurrency" => compiled_default}
           ) ==
             SemanticRevision.revision_for(
               build,
               %{"compiled_pmap_max_concurrency" => compiled_default + 2}
             )
  end
end
