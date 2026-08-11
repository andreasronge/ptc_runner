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
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.CoreToSource

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

  test "explanation work stays within the evaluator heap for many repeated violations" do
    {:ok, normalized, validator} =
      JSONSchema.compile(%{
        "type" => "object",
        "properties" => %{
          "rows" => %{"type" => "array", "items" => %{"type" => "integer", "minimum" => 1}}
        }
      })

    arguments = %{"rows" => List.duplicate(0, 5_000)}
    parent = self()
    heap_words = Limits.defaults().evaluation_heap_words

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            JSONSchema.validate(
              validator,
              normalized,
              arguments,
              Limits.defaults().evaluation_timeout_ms,
              Limits.defaults().workflow_heap_words
            )

          send(parent, {:validation_result, self(), result})
        end,
        [:monitor, {:max_heap_size, %{size: heap_words, kill: true, error_logger: false}}]
      )

    assert_receive {:validation_result, ^pid, {:error, []}}, 5_000

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
  end

  test "large valid arguments honor raised validation bounds" do
    {:ok, normalized, validator} =
      JSONSchema.compile(%{
        "type" => "object",
        "properties" => %{
          "rows" => %{"type" => "array", "items" => %{"type" => "integer"}}
        }
      })

    arguments = %{"rows" => List.duplicate(0, 175_000)}

    assert :ok = JSONSchema.validate(validator, normalized, arguments, 2_000, 16_000_000)
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

    result = Dispatcher.dispatch(state, :workflow, environment, capability.name, arguments, 100)
    refute_received {:unexpected_callback, _submitted}
    result
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
        mission_environment: mission,
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
