defmodule PtcRunner.Lisp.Java.ProjectTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Java.Callable
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Java.Project
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
