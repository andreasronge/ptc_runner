defmodule PtcRunner.Kernel.AgentMachineTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.TrustedTool

  test "exports only start and advance and stays out of the prompt inventory" do
    {:ok, bundle} = compile_machine()

    machine_refs =
      bundle.prelude.exports
      |> Enum.map(& &1.ref)
      |> Enum.filter(&String.starts_with?(&1, "agent.machine/"))
      |> Enum.sort()

    assert machine_refs == ["agent.machine/advance", "agent.machine/start"]

    assert Enum.map(Prelude.prompt_exports(bundle.prelude), & &1.ref)
           |> Enum.filter(&String.starts_with?(&1, "agent.machine/")) == []
  end

  test "boot requests the first turn without incrementing agent-turn" do
    cmd = start_and_advance(%{type: :boot})
    assert name(path(cmd, ["op"])) == "request"
    assert path(cmd, ["machine", "state", "agent-turn"]) == 0
    assert path(cmd, ["machine", "state", "phase-turn"]) == 0
    assert path(cmd, ["machine", "state", "closing?"]) == false
  end

  test "unknown events fail closed" do
    assert name(path(start_and_advance(%{type: :unknown_event}), ["op"])) == "host-failure"
    assert name(path(start_and_advance("boot"), ["op"])) == "host-failure"
  end

  test "action table: protocol, limits, provider, and unknown kinds" do
    assert name(
             path(start_and_advance(action(%{kind: :"tool-call", program: "(return 1)"})), ["op"])
           ) ==
             "check-source"

    protocol = start_and_advance(action(%{kind: :"protocol-error"}), max_turns: 2)
    assert name(path(protocol, ["op"])) == "request"
    assert path(protocol, ["machine", "state", "agent-turn"]) == 1
    assert path(protocol, ["machine", "state", "phase-turn"]) == 1

    exhausted = start_and_advance(action(%{kind: :"protocol-error"}), max_turns: 1)
    assert name(path(exhausted, ["op"])) == "done"
    assert name(path(exhausted, ["outcome", "kind"])) == "turn-limit"
    assert name(path(exhausted, ["outcome", "error", "reason"])) == "protocol-error"

    truncated = start_and_advance(action(%{kind: :"model-output-truncated", model: "alias"}))
    assert name(path(truncated, ["op"])) == "runtime-limit"
    assert path(truncated, ["payload"]) == %{"alias" => "alias"}

    max_calls =
      start_and_advance(
        action(%{kind: :"max-calls", error: %{kind: :"max-calls"}}),
        model: "m1"
      )

    assert name(path(max_calls, ["op"])) == "done"
    assert name(path(max_calls, ["outcome", "status"])) == "provider-failure"
    assert path(max_calls, ["outcome", "model"]) == "m1"

    admitted =
      start_and_advance(
        action(%{
          kind: :"provider-error",
          error: %{kind: :provider_error, reason: :not_found}
        }),
        model: "m1"
      )

    assert name(path(admitted, ["op"])) == "done"
    assert name(path(admitted, ["outcome", "status"])) == "provider-failure"

    consume =
      start_and_advance(
        action(%{
          kind: :"provider-error",
          error: %{kind: :protocol_error, reason: :argument_exceeded}
        })
      )

    assert name(path(consume, ["op"])) == "provider-consume"

    unknown = start_and_advance(action(%{kind: :unknown_kind}))
    assert name(path(unknown, ["op"])) == "host-failure"
    assert name(path(unknown, ["error", "kind"])) == "unknown-action"
  end

  test "source-check and evaluation table including unsafe closing" do
    tool = tool_action()

    valid = start_and_advance(%{type: :"source-check", action: tool, check: %{outcome: :valid}})
    assert name(path(valid, ["op"])) == "evaluate"

    invalid_last =
      start_and_advance(
        %{type: :"source-check", action: tool, check: %{outcome: :invalid}},
        max_turns: 1
      )

    assert name(path(invalid_last, ["op"])) == "done"
    assert name(path(invalid_last, ["outcome", "error", "reason"])) == "terminal-source-required"

    unavailable =
      start_and_advance(%{
        type: :"source-check",
        action: tool,
        check: %{outcome: :busy, reason: :leased}
      })

    assert name(path(unavailable, ["op"])) == "host-failure"
    assert name(path(unavailable, ["error", "kind"])) == "evaluation-unavailable"

    returned_none =
      start_and_advance(%{
        type: :evaluation,
        action: tool,
        evaluation: %{outcome: :returned, value: 7}
      })

    assert name(path(returned_none, ["op"])) == "done"
    assert name(path(returned_none, ["outcome", "status"])) == "returned"
    assert path(returned_none, ["outcome", "value"]) == 7

    returned_validate =
      start_and_advance(
        %{type: :evaluation, action: tool, evaluation: %{outcome: :returned, value: 7}},
        projector_kind: :identity
      )

    assert name(path(returned_validate, ["op"])) == "validate"
    assert path(returned_validate, ["value"]) == 7

    busy =
      start_and_advance(%{
        type: :evaluation,
        action: tool,
        evaluation: %{outcome: :busy, reason: :leased}
      })

    assert name(path(busy, ["op"])) == "host-failure"

    subordinate =
      start_and_advance(%{
        type: :evaluation,
        action: tool,
        evaluation: %{
          outcome: :limit_exceeded,
          reason: :subordinate_evaluations,
          limit_proof: %{kind: "subordinate_evaluations"}
        }
      })

    assert name(path(subordinate, ["op"])) == "runtime-limit"
    assert path(subordinate, ["payload", "proof", "kind"]) == "subordinate_evaluations"

    host = start_and_advance(host_eval(tool))
    assert name(path(host, ["op"])) == "host-failure"
    assert name(path(host, ["error", "reason"])) == "output-validation-unavailable"

    continued_last =
      start_and_advance(
        %{type: :evaluation, action: tool, evaluation: %{outcome: :continued, value: 1}},
        max_turns: 1
      )

    assert name(path(continued_last, ["op"])) == "done"
    assert name(path(continued_last, ["outcome", "error", "reason"])) == "intermediate-result"

    unsafe_close =
      start_and_advance(%{
        type: :evaluation,
        action: tool,
        evaluation: %{retryable?: false, kind: :unsafe}
      })

    assert name(path(unsafe_close, ["op"])) == "request"
    assert path(unsafe_close, ["machine", "state", "closing?"]) == true
    assert path(unsafe_close, ["machine", "state", "agent-turn"]) == 1
    assert path(unsafe_close, ["machine", "state", "phase-turn"]) == 1

    unsafe_second =
      advance_on(
        path(unsafe_close, ["machine"]),
        %{type: :evaluation, action: tool, evaluation: %{retryable?: false, kind: :unsafe}}
      )

    assert name(path(unsafe_second, ["op"])) == "done"
    assert name(path(unsafe_second, ["outcome", "kind"])) == "non-retryable-evaluation"
  end

  test "validation table and agent-turn monotonicity" do
    tool = tool_action()

    valid =
      start_and_advance(%{
        type: :validation,
        action: tool,
        projected: %{"ok" => true},
        validation: %{valid?: true}
      })

    assert name(path(valid, ["op"])) == "done"
    assert path(valid, ["outcome", "value"]) == %{"ok" => true}

    retry =
      start_and_advance(%{
        type: :validation,
        action: tool,
        projected: %{"bad" => true},
        validation: %{valid?: false}
      })

    assert name(path(retry, ["op"])) == "request"
    assert path(retry, ["machine", "state", "agent-turn"]) == 1

    exhausted =
      start_and_advance(
        %{
          type: :validation,
          action: tool,
          projected: %{"bad" => true},
          validation: %{valid?: false}
        },
        max_turns: 1
      )

    assert name(path(exhausted, ["op"])) == "result-contract-failure"
    assert path(exhausted, ["value"]) == %{"bad" => true}
    assert path(exhausted, ["agent-turns"]) == 1
  end

  test "standalone named-return validation succeeds, retries, and exhausts in place" do
    tool = tool_action()

    validate =
      start_and_advance(
        %{type: :evaluation, action: tool, evaluation: %{outcome: :returned, value: 7}},
        standalone_return_contract: true
      )

    assert name(path(validate, ["op"])) == "validate-standalone"
    assert path(validate, ["value"]) == 7

    valid =
      advance_on(path(validate, ["machine"]), %{
        type: :"standalone-validation",
        action: tool,
        value: 7,
        validation: %{valid?: true}
      })

    assert name(path(valid, ["op"])) == "done"
    assert name(path(valid, ["outcome", "status"])) == "returned"
    assert path(valid, ["outcome", "value"]) == 7

    retry =
      advance_on(path(validate, ["machine"]), %{
        type: :"standalone-validation",
        action: tool,
        value: 7,
        validation: %{valid?: false}
      })

    assert name(path(retry, ["op"])) == "request"
    assert path(retry, ["machine", "state", "phase-index"]) == 0
    assert path(retry, ["machine", "state", "phase-turn"]) == 1

    exhausted_validate =
      start_and_advance(
        %{type: :evaluation, action: tool, evaluation: %{outcome: :returned, value: 7}},
        max_turns: 1,
        standalone_return_contract: true
      )

    exhausted =
      advance_on(path(exhausted_validate, ["machine"]), %{
        type: :"standalone-validation",
        action: tool,
        value: 7,
        validation: %{valid?: false}
      })

    assert name(path(exhausted, ["op"])) == "standalone-contract-failure"
    assert name(path(exhausted, ["completion"])) == "invalid-return"
    assert path(exhausted, ["phase-index"]) == 1
    assert path(exhausted, ["max-turns"]) == 1
    assert path(exhausted, ["value"]) == 7
  end

  test "last-turn unsafe preserves closing? across a phase transition" do
    cmd =
      start_and_advance(
        %{
          type: :evaluation,
          action: tool_action(),
          evaluation: %{retryable?: false, kind: :unsafe}
        },
        phases: [
          %{"mission" => "explore", "max_turns" => 1},
          %{"mission" => "synthesize", "max_turns" => 2}
        ],
        max_turns: 1
      )

    assert name(path(cmd, ["op"])) == "request"
    assert path(cmd, ["machine", "state", "closing?"]) == true
    assert path(cmd, ["machine", "state", "phase-index"]) == 1
    assert path(cmd, ["machine", "state", "phase-turn"]) == 0
    assert path(cmd, ["machine", "state", "agent-turn"]) == 1
  end

  defp tool_action do
    %{
      :kind => :"tool-call",
      :program => "(return 1)",
      :rationale => "go",
      :"public-tool-call" => %{"id" => "t1"},
      :"tool-call-id" => "t1"
    }
  end

  defp host_eval(tool) do
    %{
      type: :evaluation,
      action: tool,
      evaluation: %{
        :"terminal-host-failure?" => true,
        :"terminal-host-failure-reason" => :output_validation_unavailable
      }
    }
  end

  defp action(action), do: %{type: :action, action: action}

  defp start_and_advance(event, opts \\ []) do
    {:ok, bundle} = compile_machine()
    context = context(opts)

    call(
      bundle,
      """
      (let [started (agent.machine/start "task" context)]
        (if (not= :ok (get started :op))
          started
          (agent.machine/advance (get started :machine) event)))
      """,
      %{"context" => context, "event" => event}
    )
  end

  defp advance_on(machine, event) do
    {:ok, bundle} = compile_machine()

    call(
      bundle,
      "(agent.machine/advance machine event)",
      %{"machine" => machine, "event" => event}
    )
  end

  defp context(opts) do
    max_turns = Keyword.get(opts, :max_turns, 2)
    model = Keyword.get(opts, :model)
    projector_kind = Keyword.get(opts, :projector_kind, :none)

    standalone_return_contract? = Keyword.get(opts, :standalone_return_contract, false)

    default_phase =
      if standalone_return_contract? do
        %{
          "mission" => "default",
          "max_turns" => max_turns,
          "return_contract" => "evidence",
          "return_contract_projection" => %{"kind" => "integer"}
        }
      else
        %{"mission" => "default", "max_turns" => max_turns}
      end

    phases = Keyword.get(opts, :phases, [default_phase])

    total = phases |> Enum.map(& &1["max_turns"]) |> Enum.sum()

    effective =
      %{
        "max_turns" => max_turns,
        "max_program_chars" => 64_000,
        "max_observation_chars" => 2048,
        "max_transcript_chars" => 262_144
      }
      |> then(fn cfg -> if model, do: Map.put(cfg, "model", model), else: cfg end)
      |> then(fn cfg ->
        if standalone_return_contract? do
          Map.put(cfg, "standalone_return_contract", %{
            name: "evidence",
            projection: %{"kind" => "integer"}
          })
        else
          cfg
        end
      end)

    standalone_return_contract =
      if standalone_return_contract? do
        %{name: "evidence", projection: %{"kind" => "integer"}}
      end

    %{
      :"effective-cfg" => effective,
      :phases => phases,
      :"total-max-turns" => total,
      :"consolidate-at-turns-remaining" => nil,
      :"max-program-chars" => 64_000,
      :"max-observation-chars" => 2048,
      :"max-transcript-chars" => 262_144,
      :"projector-kind" => projector_kind,
      :"standalone-return-contract" => standalone_return_contract,
      :"standalone-return-contract?" => standalone_return_contract?,
      :phased? => length(phases) > 1 or Keyword.has_key?(opts, :phases)
    }
  end

  defp compile_machine do
    {:ok, components} =
      Library.components(
        ~w(agent.machine agent.failure agent.feedback agent.prompt agent.retry result kernel)
      )

    Kernel.compile_bundle(components)
  end

  defp call(bundle, form, memory) do
    case Lisp.run_native(form,
           prelude: bundle.prelude,
           memory: memory,
           tools: kernel_stubs(),
           filter_context: false,
           caller: :kernel
         ) do
      {:ok, step} ->
        step.return

      {:error, step} ->
        flunk("lisp error: #{inspect(step.fail)} form=#{inspect(form)}")
    end
  end

  defp path(value, []), do: value

  defp path(map, [key | rest]) when is_map(map) do
    path(getk(map, key), rest)
  end

  defp getk(map, name) when is_map(map) and is_binary(name) do
    key =
      Enum.find(Map.keys(map), fn
        %PtcRunner.Lisp.Keyword{name: ^name} -> true
        atom when is_atom(atom) -> Atom.to_string(atom) == name
        ^name -> true
        _other -> false
      end)

    Map.get(map, key)
  end

  defp name(%PtcRunner.Lisp.Keyword{name: name}), do: name
  defp name(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  defp name(value), do: value

  defp kernel_stubs do
    Map.new(
      ~w(kernel-eval kernel-check-source kernel-mission-inventory kernel-mission-model-context kernel-result-contract),
      &{&1, %TrustedTool{function: fn _arguments -> %{status: :error} end}}
    )
  end
end
