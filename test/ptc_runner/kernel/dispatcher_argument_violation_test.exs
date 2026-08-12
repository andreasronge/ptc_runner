defmodule PtcRunner.Kernel.DispatcherArgumentViolationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.CoreToSource
  alias PtcRunner.TestSupport.TestHelpers

  test "schema rejection names the argument, violated keyword, and declared bound" do
    result =
      dispatch(
        %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          }
        },
        %{"limit" => 700}
      )

    assert %{
             status: :error,
             kind: :protocol_error,
             reason: :invalid_arguments,
             details: [
               %{argument: "limit", constraint: "maximum", expected: 50}
             ]
           } = result

    feedback = render_capability_feedback(result)

    assert feedback =~ "limit violates maximum 50"
    refute feedback =~ "700"
  end

  test "rejection details never repeat undeclared keys or submitted values" do
    result =
      dispatch(
        %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}}
        },
        %{"undeclared_secret" => "submitted-secret-value"}
      )

    assert %{details: [%{argument: "$", constraint: "additionalProperties"}]} =
             result

    rendered = inspect(result)
    refute rendered =~ "undeclared_secret"
    refute rendered =~ "submitted-secret-value"
  end

  test "semantic validator rejection remains opaque" do
    result =
      dispatch(
        %{
          "type" => "object",
          "properties" => %{"limit" => %{"type" => "integer", "maximum" => 50}}
        },
        %{"limit" => 10},
        fn _arguments -> {:error, "private semantic reason"} end
      )

    assert %{status: :error, kind: :protocol_error, reason: :invalid_arguments} = result
    refute Map.has_key?(result, :details)
    refute render_capability_feedback(result) =~ "private semantic reason"
  end

  test "malformed nested lists fail closed as invalid arguments" do
    result =
      dispatch(
        %{
          "type" => "object",
          "properties" => %{
            "rows" => %{"type" => "array", "items" => %{"type" => "integer"}}
          }
        },
        %{"rows" => [1 | 2]}
      )

    assert %{status: :error, kind: :protocol_error, reason: :invalid_arguments} = result
  end

  test "violation projection is bounded and omits oversized expected sets" do
    properties =
      Map.new(1..5, fn index ->
        {"field_#{index}",
         %{
           "type" => "string",
           "enum" => Enum.map(1..9, &"allowed_#{index}_#{&1}")
         }}
      end)

    arguments = Map.new(1..5, &{"field_#{&1}", "submitted_#{&1}"})
    result = dispatch(%{"type" => "object", "properties" => properties}, arguments)

    assert %{details: violations} = result
    assert length(violations) == 3
    assert Enum.all?(violations, &(&1.constraint == "enum"))
    assert Enum.all?(violations, &(not Map.has_key?(&1, :expected)))
    refute inspect(result) =~ "submitted_"
    refute inspect(result) =~ "allowed_"
  end

  test "enum and const literals are omitted even when small" do
    result =
      dispatch(
        %{
          "type" => "object",
          "properties" => %{
            "mode" => %{"type" => "string", "enum" => ["enum-sentinel"]},
            "version" => %{"type" => "string", "const" => "const-sentinel"}
          },
          "required" => ["mode", "version"]
        },
        %{"mode" => "submitted-mode", "version" => "submitted-version"}
      )

    assert %{details: violations} = result

    assert MapSet.new(violations) ==
             MapSet.new([
               %{argument: "mode", constraint: "enum"},
               %{argument: "version", constraint: "const"}
             ])

    rendered = inspect(result)
    refute rendered =~ "enum-sentinel"
    refute rendered =~ "const-sentinel"
    refute rendered =~ "submitted-"
  end

  test "bounded violation selection is canonical before truncation" do
    properties =
      Map.new(["zeta", "gamma", "beta", "alpha"], fn name ->
        {name, %{"type" => "integer", "maximum" => 1}}
      end)

    arguments = Map.new(Map.keys(properties), &{&1, 2})

    assert %{
             details: [
               %{argument: "alpha", constraint: "maximum", expected: 1},
               %{argument: "beta", constraint: "maximum", expected: 1},
               %{argument: "gamma", constraint: "maximum", expected: 1}
             ]
           } = dispatch(%{"type" => "object", "properties" => properties}, arguments)
  end

  test "nested and array argument paths come from the schema" do
    result =
      dispatch(
        %{
          "type" => "object",
          "properties" => %{
            "batch/list~set" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "page/size~" => %{"type" => "integer", "minimum" => 1}
                }
              }
            }
          }
        },
        %{"batch/list~set" => [%{"page/size~" => 0}]}
      )

    assert %{
             details: [
               %{
                 argument: ~S(["batch/list~set"][]["page/size~"]),
                 constraint: "minimum",
                 expected: 1
               }
             ]
           } =
             result
  end

  test "argument display distinguishes punctuation from structural path syntax" do
    dotted =
      dispatch(
        %{
          "type" => "object",
          "properties" => %{
            "a.b" => %{"type" => "integer", "maximum" => 1},
            "a" => %{
              "type" => "object",
              "properties" => %{"b" => %{"type" => "integer", "maximum" => 1}}
            },
            "line\nbreak" => %{"type" => "integer", "maximum" => 1}
          }
        },
        %{"a.b" => 2, "a" => %{"b" => 2}, "line\nbreak" => 2}
      )

    assert %{details: dotted_violations} = dotted

    assert MapSet.new(Enum.map(dotted_violations, & &1.argument)) ==
             MapSet.new([~S(["a.b"]), "a.b", ~S(["line\nbreak"])])

    refute Enum.any?(dotted_violations, &String.contains?(&1.argument, "\n"))

    array =
      dispatch(
        %{
          "type" => "object",
          "properties" => %{
            "rows[]" => %{"type" => "integer", "minimum" => 1},
            "rows" => %{"type" => "array", "items" => %{"type" => "integer", "minimum" => 1}}
          }
        },
        %{"rows[]" => 0, "rows" => [0]}
      )

    assert %{details: array_violations} = array

    assert MapSet.new(Enum.map(array_violations, & &1.argument)) ==
             MapSet.new([~S(["rows[]"]), "rows[]"])

    root =
      dispatch(
        %{
          "type" => "object",
          "properties" => %{
            "arguments" => %{"type" => "object", "properties" => %{}}
          }
        },
        %{"arguments" => %{"nested_unknown" => true}, "root_unknown" => true}
      )

    assert %{details: root_violations} = root

    assert MapSet.new(Enum.map(root_violations, & &1.argument)) ==
             MapSet.new(["$", "arguments"])

    refute inspect(root) =~ "nested_unknown"
    refute inspect(root) =~ "root_unknown"
  end

  test "validation worker exhaustion is unavailable rather than invalid" do
    {:ok, normalized, validator} =
      JSONSchema.compile(%{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "integer"}}
      })

    assert {:unavailable, :heap_exceeded} =
             JSONSchema.validate(validator, normalized, %{"value" => 1}, 1_000, 233)
  end

  test "validation worker timeout is unavailable rather than invalid" do
    {:ok, normalized, validator} =
      JSONSchema.compile(%{
        "type" => "object",
        "properties" => %{
          "rows" => %{
            "type" => "array",
            "items" => %{"type" => "integer", "minimum" => 1}
          }
        }
      })

    assert {:unavailable, :timeout} =
             JSONSchema.validate(
               validator,
               normalized,
               %{"rows" => List.duplicate(0, 10_000)},
               1,
               100_000_000
             )
  end

  test "validator failure does not charge protocol or capability budgets" do
    {result, state, sink} = dispatch_with_unavailable_validator(%{"value" => 1})

    assert %{
             status: :error,
             kind: :capability_unavailable,
             reason: :input_validation_unavailable,
             retryable?: false
           } = result

    usage = RunState.usage(state)
    assert usage.protocol_errors == 0
    assert usage.capability_calls.workflow == %{}

    refute Enum.any?(EventSink.events(sink), fn event ->
             event.type in ["capability-started", "capability-stopped"]
           end)
  end

  test "argument size admission precedes schema validation" do
    limits = Limits.defaults()
    arguments = %{"value" => String.duplicate("x", limits.capability_argument_bytes + 1)}
    {result, state, _sink} = dispatch_with_unavailable_validator(arguments)

    assert %{kind: :protocol_error, reason: :argument_exceeded} = result
    assert RunState.usage(state).protocol_errors == 1
  end

  @tag :tmp_dir
  test "plain Lisp receives details while the canonical trace omits them", %{tmp_dir: dir} do
    enum_literal = "enum-trace-sentinel"
    submitted = "submitted-trace-sentinel"

    {:ok, capability} =
      Capability.new(
        name: "schema_checked",
        effect: :read,
        input_schema: %{
          "type" => "object",
          "properties" => %{"mode" => %{"type" => "string", "enum" => [enum_literal]}},
          "required" => ["mode"]
        },
        callback: fn _ -> flunk("callback must not run") end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "schema-feedback-boundary")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source =
      ~s|(return (tool/schema_checked {"mode" "#{submitted}"}))|

    assert {:ok,
            %{
              value: %{
                "status" => "error",
                "kind" => "protocol_error",
                "reason" => "invalid_arguments",
                "details" => [%{"argument" => "mode", "constraint" => "enum"}]
              }
            }} = PtcRunner.Kernel.run(source, config)

    events = EventSink.events(sink)

    refute Enum.any?(events, fn event ->
             event.type in ["capability-started", "capability-stopped"]
           end)

    path = Path.join(dir, "canonical.jsonl")
    assert :ok = TraceLog.append_jsonl(path, events)
    canonical = File.read!(path)
    refute canonical =~ enum_literal
    refute canonical =~ submitted
    refute canonical =~ "invalid_arguments"
    refute canonical =~ ~s|"details":|
  end

  defp dispatch(schema, arguments, semantic_validator \\ nil) do
    parent = self()

    {:ok, capability} =
      Capability.new(
        name: "schema_checked",
        effect: :read,
        input_schema: schema,
        validate: semantic_validator,
        callback: fn submitted ->
          send(parent, {:unexpected_callback, submitted})
          {:ok, nil}
        end
      )

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, state} = RunState.start(Limits.defaults())

    result =
      Dispatcher.dispatch(
        state,
        :workflow,
        environment,
        capability.name,
        arguments,
        TestHelpers.dispatch_context(state, :workflow, 100),
        nil,
        nil
      )

    refute_received {:unexpected_callback, _submitted}
    result
  end

  defp dispatch_with_unavailable_validator(arguments) do
    parent = self()

    {:ok, capability} =
      Capability.new(
        name: "schema_checked",
        effect: :read,
        input_schema: %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "integer"}}
        },
        callback: fn submitted ->
          send(parent, {:unexpected_callback, submitted})
          {:ok, nil}
        end
      )

    capability = %{capability | input_validator: :forced_validator_failure}
    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, limits} = Limits.new()
    {:ok, state} = RunState.start(limits)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "validation-unavailable")

    result =
      Dispatcher.dispatch(
        state,
        :workflow,
        environment,
        capability.name,
        arguments,
        TestHelpers.dispatch_context(state, :workflow, 100),
        sink,
        nil
      )

    refute_received {:unexpected_callback, _submitted}
    {result, state, sink}
  end

  defp render_capability_feedback(result) do
    {:ok, projected_result} = Lisp.project_boundary_value(result, :kernel_json)
    {:ok, component} = Library.component("agent.feedback")
    {:ok, bundle} = PtcRunner.Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "argument-violation-feedback")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: feedback}} =
             PtcRunner.Kernel.run(
               "(return (agent.feedback/capability-error #{CoreToSource.format(%{value: projected_result})}))",
               config
             )

    feedback
  end
end
