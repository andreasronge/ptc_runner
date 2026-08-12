defmodule PtcRunner.Kernel.ToolGrantTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.ToolGrant
  alias PtcRunner.Kernel.WorkflowEnvironment

  @input_schema %{"type" => "object", "additionalProperties" => false}

  # PtcRunner.Lisp.RetainedSize deliberately refuses to size an arbitrary host
  # closure (it only sizes trusted PTC-Lisp runtime funs) - see
  # RetainedSize.referenced_binary_size/1's runtime_function?/1 guard. A
  # ToolGrant callback is a Kernel-level host closure, not a runtime one, so
  # these tests measure flat word size directly with :erts_debug.flat_size/1,
  # the same primitive the original bug report's own measurements used.
  defp flat_words(term), do: :erts_debug.flat_size(term)

  test "a callback's flat size does not depend on an unrelated capability's payload" do
    small = environment_with([capability("a"), capability("b")])

    large =
      environment_with([
        capability("a"),
        capability("b", description: String.duplicate("x", 4_000))
      ])

    assert callback_words(small, "a") == callback_words(large, "a")
  end

  test "per-callback size stays flat and the granted set grows linearly, not quadratically" do
    sizes =
      for n <- [1, 10, 50], into: %{} do
        environment = environment_with(Enum.map(1..n, &capability("cap-#{&1}")))
        {:ok, state} = RunState.start(Limits.defaults())

        grant =
          ToolGrant.capability_callbacks(
            state,
            :mission,
            environment,
            dispatch_context(),
            nil,
            nil
          )

        one_callback_words = grant |> Map.fetch!("cap-1") |> flat_words()
        total_words = flat_words(grant)

        {n, %{one: one_callback_words, total: total_words}}
      end

    # A whole-environment closure (the pre-fix shape) would make each
    # callback's own size grow with capability count, because it would carry
    # every other capability along with it. The narrowed grant must not: the
    # one-callback figure at N=50 stays equal to N=1, not fifty times larger.
    assert sizes[50].one == sizes[1].one,
           "expected a constant per-callback size, got #{inspect(sizes)}"

    # The aggregate map is N closures plus N map entries: O(N), not O(N^2).
    # A quadratic hand-over would put the 50/10 ratio near 25 (5^2); linear
    # keeps it near 5, with slack for fixed per-map overhead (the four
    # reserved runtime routes).
    ratio = sizes[50].total / sizes[10].total
    assert ratio < 10, "expected roughly linear growth, got #{inspect(sizes)}"
  end

  test "a thirteen-capability grant, shaped like private-run-analysis-v1, stays well under budget" do
    capabilities =
      for i <- 1..13 do
        capability("inspection-cap-#{i}",
          description: "Bounded one-page query over the immutable capture."
        )
      end

    environment = environment_with(capabilities)
    {:ok, state} = RunState.start(Limits.defaults())

    grant =
      ToolGrant.capability_callbacks(
        state,
        :mission,
        environment,
        dispatch_context(),
        nil,
        nil
      )

    # The pre-fix baseline for this profile's shape measured 552,708 words
    # (~4.4 MB) before evaluation started at all. A narrowed grant for the
    # same shape must land orders of magnitude below that, not merely under
    # the sandbox setup ceiling.
    assert flat_words(grant) < 20_000
  end

  test "a workflow grant can validate under the evaluator heap ceiling" do
    {:ok, checked} =
      Capability.new(
        name: "checked",
        input_schema: %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "integer"}}
        },
        callback: fn _arguments -> flunk("validation exhaustion must prevent callback entry") end
      )

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [checked])
    {:ok, state} = RunState.start(Limits.defaults())

    # REPL callbacks have workflow authority, but run inside an evaluation
    # sandbox. The explicit ceiling must therefore win over the authority's
    # much larger workflow heap.
    grant =
      ToolGrant.capability_callbacks(
        state,
        :workflow,
        environment,
        dispatch_context(validation_heap_words: 233, mission_name: nil),
        nil,
        nil
      )

    assert %{
             status: :error,
             kind: :capability_unavailable,
             reason: :input_validation_unavailable
           } = grant["checked"].(%{"value" => 1})
  end

  test "validation deadline reserves time to persist terminal host provenance" do
    {:ok, checked} =
      Capability.new(
        name: "checked",
        effect: :read,
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "rows" => %{
              "type" => "array",
              "items" => %{"type" => "integer", "minimum" => 1}
            }
          }
        },
        callback: fn _arguments -> flunk("validator timeout must prevent callback entry") end
      )

    {:ok, environment} = MissionEnvironment.new(capabilities: [checked])
    {:ok, state} = RunState.start(Limits.defaults())
    assert {:ok, %{}, [], lease} = RunState.reserve_evaluation(state, "default", :fail_fast)

    grant =
      ToolGrant.capability_callbacks(
        state,
        :mission,
        environment,
        dispatch_context(
          validation_heap_words: 100_000_000,
          evaluation_lease: lease,
          validation_deadline_ms: System.monotonic_time(:millisecond) + 30
        ),
        nil,
        nil
      )

    assert %{
             status: :error,
             kind: :capability_unavailable,
             reason: :input_validation_unavailable
           } = grant["checked"].(%{"rows" => List.duplicate(0, 10_000)})

    assert {:ok, %{terminal_host_failure?: true}} =
             RunState.release_evaluation_status(state, lease)
  end

  defp callback_words(environment, name) do
    {:ok, state} = RunState.start(Limits.defaults())

    grant =
      ToolGrant.capability_callbacks(
        state,
        :mission,
        environment,
        dispatch_context(),
        nil,
        nil
      )

    grant |> Map.fetch!(name) |> flat_words()
  end

  defp environment_with(capabilities) do
    {:ok, environment} = MissionEnvironment.new(capabilities: capabilities)
    environment
  end

  defp dispatch_context(overrides \\ []) do
    Map.merge(
      %{
        timeout_ms: 1_000,
        validation_heap_words: Limits.defaults().evaluation_heap_words,
        evaluation_lease: nil,
        validation_deadline_ms: nil,
        mission_name: "default"
      },
      Map.new(overrides)
    )
  end

  defp capability(name, opts \\ []) do
    {:ok, capability} =
      Capability.new(
        [
          name: name,
          callback: fn _arguments -> {:ok, %{}} end,
          input_schema: @input_schema
        ] ++ opts
      )

    capability
  end
end
