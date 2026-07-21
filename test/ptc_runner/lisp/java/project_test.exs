defmodule PtcRunner.Lisp.Java.ProjectTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Java.Callable
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Java.Project
  alias PtcRunner.Lisp.Java.Time.Duration
  alias PtcRunner.Lisp.Java.Time.Instant
  alias PtcRunner.Lisp.Java.Time.LocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate
  alias PtcRunner.Lisp.Result

  test "projects valid Java leaves and retains them only at the native boundary" do
    assert {:ok, callable} = Callable.new(:boolean_parse_boolean)
    assert {:ok, primitive} = Primitive.new(:long, 7)

    assert {:ok, %{callable: "#java[java.lang.Boolean/parseBoolean]", value: 7}} =
             Project.project(%{callable: callable, value: primitive}, :public)

    assert {:ok, ^callable} = Project.project(callable, :native)
    assert Lisp.externalize_value(callable) == "#java[java.lang.Boolean/parseBoolean]"

    assert Lisp.externalize_memory(%{"parser" => callable}) == %{
             "parser" => "#java[java.lang.Boolean/parseBoolean]"
           }

    assert Format.to_clojure(%{parser: callable}) ==
             {"{:parser #java[java.lang.Boolean/parseBoolean]}", false}

    assert Format.to_string(%{parser: callable}) ==
             "%{parser: #java[java.lang.Boolean/parseBoolean]}"

    assert {:error,
            {:unsupported_java_boundary_value, [], :tool_argument, :boolean_parse_boolean}} =
             Project.project(callable, :tool_argument)
  end

  test "projects temporal wrappers according to public and direct-tool contracts" do
    {:ok, local_date} = LocalDate.parse(["2024-01-02"])
    {:ok, instant} = Instant.parse(["2024-01-02T03:04:05.123456Z"])
    {:ok, precise_instant} = Instant.parse(["2024-01-02T03:04:05.123456789Z"])
    {:ok, duration} = Duration.new(1, 500_000_000)
    {:ok, date} = JavaDate.new(1)

    native = [local_date, instant, duration, date]

    assert {:ok, ^native} = Project.project(native, :native)

    assert {:ok,
            [
              "2024-01-02",
              "2024-01-02T03:04:05.123456Z",
              "PT1.5S",
              "1970-01-01T00:00:00.001Z"
            ]} = Project.project(native, :public)

    assert {:ok, "2024-01-02T03:04:05.123456Z"} =
             Project.project(instant, :tool_argument, :string)

    assert {:ok, %DateTime{} = datetime} =
             Project.project(instant, :tool_argument, :datetime)

    assert DateTime.to_iso8601(datetime) == "2024-01-02T03:04:05.123456Z"

    assert {:ok, ~U[1970-01-01 00:00:00.001000Z]} =
             Project.project(date, :tool_argument, :datetime)

    assert {:error, {:inexact_java_boundary_conversion, [], :tool_argument, :instant}} =
             Project.project(precise_instant, :tool_argument, :datetime)

    for value <- [local_date, duration] do
      assert {:error, {:unsupported_java_boundary_value, [], :tool_argument, _profile}} =
               Project.project(value, :tool_argument, :datetime)
    end

    for value <- native do
      assert {:error, {:unsupported_java_boundary_value, [], :tool_result, _profile}} =
               Project.project(value, :tool_result)
    end
  end

  test "temporal projection rejects forged values and detects canonical collisions" do
    {:ok, local_date} = LocalDate.parse(["2024-01-02"])
    forged = %Instant{epoch_second: 0, nano: -1}

    assert {:error, {:invalid_java_value, [], :instant}} =
             Project.project(forged, :public)

    assert {:error, {:java_projection_collision, [], :map}} =
             Project.project(%{local_date => :native, "2024-01-02" => :text}, :public)

    assert {:error, {:java_projection_collision, [], :set}} =
             Project.project(MapSet.new([local_date, "2024-01-02"]), :kernel_json)
  end

  test "direct tools receive prepared temporal values and reject temporal results" do
    {:ok, instant} = Instant.parse(["2024-01-02T03:04:05.123456Z"])
    parent = self()

    tool = fn args ->
      send(parent, {:temporal_called, args})
      :ok
    end

    assert {:ok, %{return: :ok}} =
             Lisp.run_native("(tool/echo {:at instant})",
               memory: %{"instant" => instant},
               tools: %{"echo" => {tool, "(at :datetime) -> :any"}}
             )

    assert_receive {:temporal_called, %{"at" => %DateTime{} = callback_instant}}
    assert DateTime.to_iso8601(callback_instant) == "2024-01-02T03:04:05.123456Z"

    returning_tool = {fn _args -> instant end, :skip}

    assert {:error, %{fail: %{reason: :tool_error}}} =
             Lisp.run("(tool/echo {})", tools: %{"echo" => returning_tool})
  end

  test "signed tool projection scans Java values nested in ordinary structs" do
    {:ok, instant} = Instant.parse(["2024-01-02T03:04:05.123456Z"])
    parent = self()

    tool = fn args ->
      send(parent, {:struct_temporal_args, args})
      :ok
    end

    assert {:ok, %{return: :ok}} =
             Lisp.run_native("(tool/echo {:payload data/result})",
               context: %{"result" => %Result{return: instant}},
               tools: %{"echo" => {tool, "(payload :any) -> :any"}}
             )

    assert_receive {:struct_temporal_args,
                    %{"payload" => %Result{return: "2024-01-02T03:04:05.123456Z"}}}
  end

  test "untyped map tool contracts project nested Java values as any" do
    {:ok, instant} = Instant.parse(["2024-01-02T03:04:05.123456Z"])
    parent = self()

    tool = fn args ->
      send(parent, {:untyped_map_args, args})
      :ok
    end

    assert {:ok, %{return: :ok}} =
             Lisp.run_native("(tool/echo {:payload {:at instant}})",
               memory: %{"instant" => instant},
               tools: %{"echo" => {tool, "(payload :map) -> :any"}}
             )

    assert_receive {:untyped_map_args, %{"payload" => %{"at" => "2024-01-02T03:04:05.123456Z"}}}
  end

  test "direct tool map keys remain Java values until boundary projection" do
    {:ok, local_date} = LocalDate.parse(["2024-01-02"])
    {:ok, int} = Primitive.new(:int, 1)
    forged = %Instant{epoch_second: 0, nano: -1}
    parent = self()

    tool = fn args ->
      send(parent, {:java_key_args, args})
      :ok
    end

    assert {:ok, %{return: :ok}} =
             Lisp.run_native("(tool/echo data/args)",
               context: %{"args" => %{local_date => :native}},
               tools: %{"echo" => {tool, :skip}}
             )

    assert_receive {:java_key_args, %{"2024_01_02" => :native}}

    assert {:ok, %{return: :ok}} =
             Lisp.run_native("(tool/echo data/args)",
               context: %{"args" => %{int => :java}},
               tools: %{"echo" => {tool, :skip}}
             )

    assert_receive {:java_key_args, %{"1" => :java}}

    for args <- [
          %{forged => :forged},
          %{local_date => :native, "2024-01-02" => :text},
          %{int => :java, 1 => :ordinary}
        ] do
      assert {:error, %{fail: %{reason: :tool_error}}} =
               Lisp.run_native("(tool/echo data/args)",
                 context: %{"args" => args},
                 tools: %{"echo" => {tool, :skip}}
               )

      refute_received {:java_key_args, _args}
    end
  end

  test "normalized signature field names retain temporal contracts recursively" do
    {:ok, instant} = Instant.parse(["2024-01-02T03:04:05.123456Z"])
    parent = self()

    tool = fn args ->
      send(parent, {:normalized_temporal_args, args})
      :ok
    end

    signature = "(event-time :datetime, payload {items [{event-time :datetime}]}) -> :any"

    assert {:ok, %{return: :ok}} =
             Lisp.run_native(
               "(tool/echo {:event-time instant :payload {:items [{:event-time instant}]}})",
               memory: %{"instant" => instant},
               tools: %{"echo" => {tool, signature}}
             )

    assert_receive {:normalized_temporal_args,
                    %{
                      "event_time" => %DateTime{} = top_level,
                      "payload" => %{"items" => [%{"event_time" => %DateTime{} = nested}]}
                    }}

    assert DateTime.to_iso8601(top_level) == "2024-01-02T03:04:05.123456Z"
    assert DateTime.to_iso8601(nested) == "2024-01-02T03:04:05.123456Z"
  end

  test "rejects forged primitives and projection collisions" do
    forged = %Primitive{kind: :int, value: 9_999_999_999}

    assert {:error, {:invalid_java_value, [{:list, 0}], :int}} =
             Project.project([forged], :public)

    assert {:ok, int} = Primitive.new(:int, 1)
    assert {:ok, long} = Primitive.new(:long, 1)

    assert {:error, {:java_projection_collision, [], :set}} =
             Project.project(MapSet.new([int, long]), :public)

    assert {:error, {:java_projection_collision, [], :map}} =
             Project.project(%{int => :int, long => :long}, :public)

    assert {:error, step} =
             Lisp.run("data/value", context: %{"value" => %{int => :int, long => :long}})

    assert step.fail.reason == :java_projection_error
    assert step.return == nil

    assert {:error, step} = Lisp.run("nil", memory: %{"forged" => forged})
    assert step.fail.reason == :java_projection_error
    assert step.memory == %{}
  end

  test "ordinary PTC numeric consumers validate and erase primitive provenance" do
    assert {:ok, primitive} = Primitive.new(:long, 7)

    assert Format.to_clojure(primitive) == {"7", false}
    assert Helpers.describe_type(primitive) == "number"

    assert {:ok, step} =
             Lisp.run_native(
               "[(number? p) (integer? p) (float? p) (+ p 1)]",
               memory: %{"p" => primitive}
             )

    assert step.return == [true, true, false, 8]

    assert {:ok, %{return: [8]}} =
             Lisp.run_native("(map inc data/values)", context: %{"values" => [primitive]})

    assert {:ok, int} = Primitive.new(:int, 1)

    assert {:ok, %{return: [^int, 2, ^primitive]}} =
             Lisp.run_native("(sort data/values)",
               context: %{"values" => [primitive, 2, int]}
             )

    assert int.value == 1

    assert {:ok, float} = Primitive.new(:float, 1.1)
    refute float.value === 1.1
    assert Primitive.valid?(float)
    refute Primitive.valid?(%Primitive{kind: :float, value: 1.1})
  end

  test "integer-index consumers unwrap Java primitives directly and through higher-order calls" do
    assert {:ok, zero} = Primitive.new(:long, 0)
    assert {:ok, one} = Primitive.new(:int, 1)
    assert {:ok, two} = Primitive.new(:long, 2)

    assert {:ok, %{return: ["a", ["a"], ["b"], [0, 1], "b", ["a"]]}} =
             Lisp.run_native(
               ~S|[(nth ["a"] zero) (take one ["a" "b"]) | <>
                 ~S|(drop one ["a" "b"]) (range zero two) (subs "ab" one) | <>
                 ~S|(map (fn [index] (nth ["a"] index)) [zero])]|,
               memory: %{"zero" => zero, "one" => one, "two" => two}
             )
  end

  test "numeric argument positions depend on builtin arity" do
    assert {:ok, one} = Primitive.new(:int, 1)

    assert {:ok, [^one]} = Primitive.prepare_arguments(:"drop-last", [one])
    assert {:ok, [1, []]} = Primitive.prepare_arguments(:"drop-last", [one, []])

    assert {:ok, [1, ^one]} = Primitive.prepare_arguments(:partition, [one, one])
    assert {:ok, [1, 1, []]} = Primitive.prepare_arguments(:partition, [one, one, []])

    assert {:ok, [1, ^one]} = Primitive.prepare_arguments(:"partition-all", [one, one])
    assert {:ok, [1, 1, []]} = Primitive.prepare_arguments(:"partition-all", [one, one, []])
  end

  test "sort comparators erase Java primitive provenance through shared callable dispatch" do
    assert {:ok, before} = Primitive.new(:int, -1)

    assert {:ok, %{return: [2, 1]}} =
             Lisp.run_native("(sort (fn [_left _right] before) [2 1])",
               memory: %{"before" => before}
             )

    assert {:error, step} = Lisp.run("(sort Boolean/parseBoolean [2 1])")
    assert step.fail.reason == :java_arity_error
  end

  test "numeric collection consumers erase primitive provenance in nested values and keys" do
    assert {:ok, one} = Primitive.new(:long, 1)
    assert {:ok, three} = Primitive.new(:int, 3)

    assert {:ok,
            %{
              return: [
                4,
                2.0,
                4,
                2.0,
                [^one, ^three],
                ^one,
                ^three
              ]
            }} =
             Lisp.run_native(
               "[(sum [one three]) (avg [one three]) " <>
                 "(sum-by identity [one three]) (avg-by identity [one three]) " <>
                 "(sort-by identity [three one]) (min-by identity [three one]) " <>
                 "(max-by identity [three one])]",
               memory: %{"one" => one, "three" => three}
             )
  end

  test "return signatures validate projected Java primitive payloads" do
    assert {:ok, primitive} = Primitive.new(:long, 7)

    assert {:ok, %{return: ^primitive, signature: ":int"}} =
             Lisp.run_native("value", memory: %{"value" => primitive}, signature: ":int")

    assert {:ok, %{return: [^primitive], signature: "[:int]"}} =
             Lisp.run_native("[value]", memory: %{"value" => primitive}, signature: "[:int]")
  end

  test "non-numeric PTC operations preserve primitive provenance" do
    assert {:ok, primitive} = Primitive.new(:long, 7)

    assert {:ok, %{return: [^primitive, ^primitive, ^primitive]}} =
             Lisp.run_native(
               "[(identity p) ((fn [value] value) p) (first (map identity [p]))]",
               memory: %{"p" => primitive}
             )
  end

  test "recurses through struct fields at every boundary" do
    assert {:ok, callable} = Callable.new(:boolean_parse_boolean)
    value = %Result{return: callable}

    assert {:ok, %Result{return: "#java[java.lang.Boolean/parseBoolean]"}} =
             Project.project(value, :public)

    assert {:error,
            {:unsupported_java_boundary_value, [{:struct_field, :return}], :tool_result,
             :boolean_parse_boolean}} = Project.project(value, :tool_result)
  end

  test "projects Java primitives according to the declared tool signature" do
    assert {:ok, primitive} = Primitive.new(:long, 7)
    parent = self()

    tool = fn args ->
      send(parent, {:called, args})
      :ok
    end

    assert {:ok, %{return: :ok}} =
             Lisp.run_native("(tool/echo {:value p})",
               memory: %{"p" => primitive},
               tools: %{"echo" => {tool, "(value :int) -> :any"}}
             )

    assert_receive {:called, %{"value" => 7}}

    assert {:ok, %{return: :ok}} =
             Lisp.run_native("(tool/echo {:payload {:items [p]}})",
               memory: %{"p" => primitive},
               tools: %{"echo" => {tool, "(payload {items [:int]}) -> :any"}}
             )

    assert_receive {:called, %{"payload" => %{"items" => [7]}}}

    assert {:error, step} =
             Lisp.run_native("(tool/echo {:value p})",
               memory: %{"p" => primitive},
               tools: %{"echo" => {tool, "(value :string) -> :any"}}
             )

    assert step.fail.reason == :tool_error
    refute_received {:called, _args}

    assert {:error, step} =
             Lisp.run_native("(tool/echo {:value p})",
               memory: %{"p" => primitive},
               tools: %{"echo" => {tool, "(value :datetime) -> :any"}}
             )

    assert step.fail.reason == :tool_error
    refute_received {:called, _args}

    assert {:ok, %{return: :ok}} =
             Lisp.run_native("(tool/echo {:value p})",
               memory: %{"p" => primitive},
               tools: %{"echo" => {tool, :skip}}
             )

    assert_receive {:called, %{"value" => 7}}
  end

  test "primitive-free tool calls do not parse signature metadata for Java projection" do
    parent = self()

    tool = fn args ->
      send(parent, {:called, args})
      args
    end

    assert {:ok, %{return: %{"value" => 7}}} =
             Lisp.run_native("(tool/echo {:value 7})",
               tools: %{"echo" => {tool, "not a valid signature"}}
             )

    assert_receive {:called, %{"value" => 7}}
  end

  test "tool callbacks never receive or return Java authority" do
    assert {:ok, callable} = Callable.new(:boolean_parse_boolean)
    parent = self()

    tool =
      {fn args ->
         send(parent, {:called, args})
         :ok
       end, :skip}

    assert {:error, step} =
             Lisp.run("(tool/echo {:parser parser})",
               memory: %{"parser" => callable},
               tools: %{"echo" => tool}
             )

    assert step.fail.reason == :tool_error
    refute_received {:called, _args}

    returning_tool = {fn _args -> callable end, :skip}

    assert {:error, step} = Lisp.run("(tool/echo {})", tools: %{"echo" => returning_tool})
    assert step.fail.reason == :tool_error

    assert [%{name: "echo", result: nil, error: error}] = step.tool_calls
    assert error =~ "java_projection_error"

    nested_returning_tool = {fn _args -> %Result{return: callable} end, :skip}

    assert {:error, step} =
             Lisp.run("(tool/echo {})", tools: %{"echo" => nested_returning_tool})

    assert step.fail.reason == :tool_error
  end

  test "rejects malformed struct-shaped host data without raising" do
    malformed = %{__struct__: PtcRunner.MissingJavaProjectionStruct, payload: 1}

    assert {:error, {:invalid_projection_struct, [], PtcRunner.MissingJavaProjectionStruct}} =
             Project.project(malformed, :public)

    assert {:error, step} =
             Lisp.run("data/value", context: %{"value" => malformed}, filter_context: false)

    assert step.fail.reason == :java_projection_error
  end

  test "rejects Java struct-shaped maps with undeclared fields" do
    malformed_callable = %{
      __struct__: Callable,
      reference_id: :boolean_parse_boolean,
      injected: :authority
    }

    malformed_primitive = %{__struct__: Primitive, kind: :int, value: 1, injected: :authority}

    assert {:error, {:invalid_java_value, [], :boolean_parse_boolean}} =
             Project.project(malformed_callable, :native)

    assert {:error, {:invalid_java_value, [], :int}} =
             Project.project(malformed_primitive, :public)
  end

  test "rejects Java struct-shaped maps with missing fields at every boundary" do
    malformed_callable = %{__struct__: Callable}
    malformed_primitive = %{__struct__: Primitive, kind: :int}

    assert {:error, {:invalid_java_value, [], nil}} =
             Project.project(malformed_callable, :native)

    assert {:error, {:invalid_java_value, [], :int}} =
             Project.project(malformed_primitive, :public)

    assert {:error, condition} = Callable.invoke(malformed_callable, ["true"])
    assert condition.category == :unsupported_java_member

    assert Format.to_string(malformed_callable) == ~S("#<invalid-java-value>")
    assert Format.to_string(malformed_primitive) == ~S("#<invalid-java-value>")
  end

  test "rejects ordinary struct-shaped maps with missing fields instead of injecting defaults" do
    malformed = %{__struct__: Result}

    assert {:error, {:invalid_projection_struct, [], Result}} =
             Project.project(malformed, :public)
  end
end
