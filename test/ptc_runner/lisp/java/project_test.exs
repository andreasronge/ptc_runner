defmodule PtcRunner.Lisp.Java.ProjectTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.ExternalizedCollision
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Java.Callable
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Java.Project
  alias PtcRunner.Lisp.Java.Time.Duration
  alias PtcRunner.Lisp.Java.Time.Instant
  alias PtcRunner.Lisp.Java.Time.LocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate
  alias PtcRunner.Lisp.Keyword
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

  test "rejects improper lists at Java and public projection boundaries" do
    malformed = [1 | 2]

    assert {:error, {:invalid_projection_list, []}} = Project.project(malformed, :public)

    assert {:error, {:invalid_projection_list, []}} =
             Project.project(malformed, :tool_argument, "(x: int) -> any")

    assert {:error, {:java_projection_error, {:invalid_projection_list, []}}} =
             Lisp.externalize_value(malformed)
  end

  test "public Step projection sanitizes every auxiliary field" do
    secret = fn -> "captured-secret" end

    step = %{
      Result.ok(:ok, %{"hidden" => secret})
      | messages: [%{callable: secret, ref: {:symbol_ref, "server/tool"}}],
        field_descriptions: %{result: {:symbol_ref, "result/value"}},
        tools: %{hidden: secret}
    }

    {:ok, projected_native} = Lisp.project_native_result({:ok, step})

    for projected <- [projected_native, Lisp.externalize_value(step)] do
      assert [%{callable: %Format.Fn{}, ref: %Format.SymbolRef{name: "server/tool"}}] =
               projected.messages

      assert projected.field_descriptions == %{
               result: %Format.SymbolRef{name: "result/value"}
             }

      assert %{hidden: %Format.Fn{}} = projected.tools
      assert %Format.Fn{} = projected.memory["hidden"]
    end
  end

  test "public continuation documents Java-capturing closures as observation-only" do
    source = ~S|(def f (let [parse Integer/parseInt] (fn [value] (parse value))))|

    assert {:ok, public_first} = Lisp.run(source)

    assert {:error, %{fail: %{reason: :not_callable}}} =
             Lisp.run(~S|(f "42")|, memory: public_first.memory)

    assert {:ok, native_first} = Lisp.run_native(source)

    assert {:ok, %{return: %Primitive{kind: :int, value: 42}}} =
             Lisp.run_native(~S|(f "42")|, memory: native_first.memory)
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

  test "tool-result symbol references reject inverse map and set collisions" do
    symbol = %Format.SymbolRef{name: "x"}
    native = {:symbol_ref, "x"}

    for result <- [
          %{symbol => :public, native => :native},
          MapSet.new([symbol, native])
        ] do
      assert {:error, %{fail: %{reason: :tool_error}}} =
               Lisp.run("(tool/echo {})", tools: %{"echo" => {fn _args -> result end, :skip}})
    end
  end

  test "Java projection rejects malformed MapSet structs before enumeration" do
    malformed = Map.put(MapSet.new([%Format.SymbolRef{name: "x"}]), :map, :invalid)
    forged = Map.put(MapSet.new([%Format.SymbolRef{name: "x"}]), :extra, true)

    for value <- [malformed, forged],
        boundary <- [:native, :continuation, :public, :tool_argument, :tool_result, :kernel_json] do
      assert {:error, {:invalid_projection_struct, [], MapSet}} =
               Project.project(value, boundary)
    end

    for value <- [malformed, forged] do
      assert {:error, {:invalid_projection_struct, [], MapSet}} =
               Project.project(value, :tool_argument, "(value :int) -> :any")
    end
  end

  test "tool results reject malformed symbol-reference wrappers" do
    for malformed <- [
          %Format.SymbolRef{name: %{}},
          {:symbol_ref, <<255>>}
        ] do
      assert {:error, %{fail: %{reason: :tool_error}}} =
               Lisp.run("(tool/echo {})",
                 tools: %{"echo" => {fn _args -> malformed end, :skip}}
               )
    end
  end

  test "tool-result symbol references are internalized through validated structs" do
    symbol = %Format.SymbolRef{name: "x"}
    result = %Result{return: symbol}

    assert {:ok, %{return: %Result{return: ^symbol}}} =
             Lisp.run("(tool/echo {})", tools: %{"echo" => {fn _args -> result end, :skip}})
  end

  test "tool-result symbol references use their public wrapper when forwarded to another tool" do
    parent = self()
    symbol = %Format.SymbolRef{name: "x"}

    tools = %{
      "source" => {fn _args -> symbol end, :skip},
      "sink" =>
        {fn args ->
           send(parent, {:symbol_args, args})
           :ok
         end, :skip}
    }

    assert {:ok, %{return: :ok}} =
             Lisp.run(
               "(let [ref (tool/source {})] (tool/sink {:ref ref :by-ref {ref 1}}))",
               tools: tools
             )

    assert_receive {:symbol_args, %{"ref" => ^symbol, "by_ref" => %{"'x" => 1}}}
  end

  test "tool-result structs preserve symbol-reference map keys when forwarded" do
    parent = self()
    symbol = %Format.SymbolRef{name: "x"}

    tools = %{
      "source" => {fn _args -> %Result{return: %{symbol => 1}} end, :skip},
      "sink" =>
        {fn args ->
           send(parent, {:symbol_struct_args, args})
           :ok
         end, :skip}
    }

    assert {:ok, %{return: :ok}} =
             Lisp.run(
               "(let [result (tool/source {})] (tool/sink {:payload result}))",
               tools: tools
             )

    assert_receive {:symbol_struct_args, %{"payload" => %Result{return: %{"'x" => 1}}}}
  end

  test "tool arguments reject malformed native symbol-reference map keys" do
    parent = self()

    tool = fn args ->
      send(parent, {:malformed_symbol_args, args})
      :ok
    end

    for malformed <- [
          {:symbol_ref, "x y"},
          %Format.SymbolRef{name: "x y"},
          %{__struct__: Format.SymbolRef},
          %{__struct__: Format.SymbolRef, name: "x", extra: true}
        ],
        saved <- [%{malformed => 1}, %Result{return: %{malformed => 1}}] do
      assert {:error, %{fail: %{reason: :invalid_symbol_ref}}} =
               Lisp.run_native("(tool/sink {:payload saved})",
                 memory: %{saved: saved},
                 tools: %{"sink" => {tool, :skip}}
               )
    end

    refute_receive {:malformed_symbol_args, _args}
  end

  test "tool arguments preserve exact quoted-symbol key spelling" do
    parent = self()

    tool =
      {fn args ->
         send(parent, {:quoted_symbol_args, args})
         :ok
       end, :skip}

    assert {:ok, %{return: :ok}} =
             Lisp.run("(tool/sink {'foo-bar 1 :nested {'foo-bar 2}})",
               tools: %{"sink" => tool}
             )

    assert_receive {:quoted_symbol_args, %{"'foo-bar" => 1, "nested" => %{"'foo-bar" => 2}}}

    assert {:ok, %{return: :ok}} =
             Lisp.run("(tool/sink {'foo-bar 1 'foo_bar 2})",
               tools: %{"sink" => tool}
             )

    assert_receive {:quoted_symbol_args, %{"'foo-bar" => 1, "'foo_bar" => 2}}
  end

  test "native tool arguments reject malformed keyword wrappers" do
    parent = self()

    tool =
      {fn args ->
         send(parent, {:keyword_args, args})
         :ok
       end, :skip}

    for malformed <- [
          %PtcRunner.Lisp.Keyword{name: %{}},
          %{__struct__: PtcRunner.Lisp.Keyword, name: "valid", extra: true}
        ],
        saved <- [%{"value" => malformed}, %{malformed => "value"}] do
      assert {:error, %{fail: %{reason: :invalid_keyword}}} =
               Lisp.run_native("(tool/sink saved)",
                 memory: %{"saved" => saved},
                 tools: %{"sink" => tool}
               )
    end

    refute_receive {:keyword_args, _args}
  end

  test "tool arguments project and validate boundary values inside composite keys" do
    parent = self()
    {:ok, int} = Primitive.new(:int, 1)
    forged_int = %Primitive{kind: :int, value: 9_999_999_999}

    tool = fn args ->
      send(parent, {:composite_symbol_args, args})
      :ok
    end

    assert {:ok, %{return: :ok}} =
             Lisp.run("(tool/sink {['foo] 1})", tools: %{"sink" => {tool, :skip}})

    assert_receive {:composite_symbol_args, %{"['foo]" => 1}}

    assert {:ok, %{return: :ok}} =
             Lisp.run_native("(tool/sink saved)",
               memory: %{saved: %{{{:symbol_ref, "foo"}} => 1}},
               tools: %{"sink" => {tool, :skip}}
             )

    assert_receive {:composite_symbol_args, %{"{'foo}" => 1}}

    assert {:ok, %{return: :ok}} =
             Lisp.run_native("(tool/sink saved)",
               memory: %{saved: %{[int] => :vector, {int} => :tuple}},
               tools: %{"sink" => {tool, :skip}}
             )

    assert_receive {:composite_symbol_args, %{"[1]" => :vector, "{1}" => :tuple}}

    for malformed_key <- [
          [%Format.SymbolRef{name: "x y"}],
          {{:symbol_ref, "x y"}},
          %Result{return: {:symbol_ref, "x y"}}
        ] do
      assert {:error, %{fail: %{reason: :invalid_symbol_ref}}} =
               Lisp.run_native("(tool/sink saved)",
                 memory: %{saved: %{malformed_key => 1}},
                 tools: %{"sink" => {tool, :skip}}
               )
    end

    for malformed_key <- [
          [forged_int],
          {forged_int},
          %Result{return: forged_int}
        ] do
      assert {:error, %{fail: %{reason: :tool_error}}} =
               Lisp.run_native("(tool/sink saved)",
                 memory: %{saved: %{malformed_key => 1}},
                 tools: %{"sink" => {tool, :skip}}
               )
    end

    refute_receive {:composite_symbol_args, _args}
  end

  test "tool-result symbol collisions nested in validated structs are rejected" do
    symbol = %Format.SymbolRef{name: "x"}
    result = %Result{return: %{symbol => :public, {:symbol_ref, "x"} => :native}}

    assert {:error, %{fail: %{reason: :tool_error}}} =
             Lisp.run("(tool/echo {})", tools: %{"echo" => {fn _args -> result end, :skip}})
  end

  test "strict public projection detects JSON key collisions nested in structs" do
    result = %Result{return: %{{:symbol_ref, "x"} => :symbol, "'x" => :string}}

    assert {:error, {:public_projection_collision, [{:struct_field, :return}], :map}} =
             Lisp.project_boundary_value(result, :kernel_json)
  end

  test "public projection rejects malformed symbol-reference outputs" do
    for malformed_native <- [
          {:symbol_ref, <<255>>},
          {:symbol_ref, ""},
          {:symbol_ref, "x y"},
          {:symbol_ref, "x\n(tool/other {})"},
          {:symbol_ref, "λ"}
        ] do
      assert {:error, {:invalid_symbol_ref, _path}} =
               Lisp.project_boundary_value(malformed_native, :kernel_json)
    end

    assert {:error, {:invalid_symbol_ref, _path}} =
             Lisp.project_boundary_value(%Format.SymbolRef{name: %{}}, :kernel_json)

    assert {:error, {:invalid_projection_struct, _path, Format.SymbolRef}} =
             Lisp.project_boundary_value(%{__struct__: Format.SymbolRef}, :kernel_json)
  end

  test "native Step and memory projection reject malformed symbol references" do
    malformed = {:symbol_ref, <<255>>}

    assert {:error, {:symbol_ref_projection_error, {:invalid_symbol_ref, _path}}} =
             Lisp.externalize_value(malformed)

    assert {:error, %{fail: %{reason: :invalid_symbol_ref}, memory: %{}}} =
             Lisp.project_native_result({:ok, %Result{return: malformed, memory: %{}}})

    assert {:error, %{fail: %{reason: :invalid_symbol_ref}, memory: %{}}} =
             Lisp.project_native_result(
               {:ok, %Result{return: :ok, memory: %{"bad" => malformed}}}
             )

    assert {:error, {:symbol_ref_projection_error, {:invalid_symbol_ref, _path}}} =
             Lisp.externalize_memory(%{"bad" => malformed})
  end

  test "memory projection externalizes native symbol-reference keys without losing collisions" do
    symbol = %Format.SymbolRef{name: "x"}

    assert Lisp.externalize_memory(%{{:symbol_ref, "x"} => :native}) == %{symbol => :native}

    externalized =
      Lisp.externalize_memory(%{
        symbol => :public,
        {:symbol_ref, "x"} => :native
      })

    assert map_size(externalized) == 2
    assert externalized |> Map.values() |> Enum.sort() == [:native, :public]

    assert Enum.all?(Map.keys(externalized), fn
             %ExternalizedCollision{collection: :map, value: ^symbol} -> true
             _key -> false
           end)
  end

  test "Java projection errors preserve valid effects and discard malformed diagnostics" do
    malformed = {:symbol_ref, <<255>>}
    tool_call = %{name: "echo", arguments: %{}, result: :ok}

    step = %{
      Result.ok(%Primitive{kind: :int, value: :invalid}, %{})
      | prints: ["tool completed"],
        tool_calls: [tool_call],
        child_traces: ["child-1"],
        child_steps: [%Result{return: malformed}]
    }

    assert {:error,
            %{
              fail: %{reason: :java_projection_error},
              memory: %{},
              prints: ["tool completed"],
              tool_calls: [^tool_call],
              child_traces: ["child-1"],
              child_steps: [%{fail: %{reason: :invalid_symbol_ref}}]
            }} = Lisp.project_native_result({:ok, step})
  end

  test "symbol projection errors discard malformed child-trace metadata" do
    step = %{Result.ok(:ok, %{}) | child_traces: [{:symbol_ref, <<255>>}]}

    assert {:error,
            %{
              fail: %{reason: :invalid_symbol_ref},
              child_traces: []
            }} = Lisp.project_native_result({:ok, step})
  end

  test "malformed tool child-trace metadata cannot erase the effect ledger" do
    parent = self()

    tool = fn _args ->
      send(parent, :tool_called)
      %{__child_trace_id__: {:symbol_ref, <<255>>}, value: :ok}
    end

    assert {:ok,
            %{
              return: :ok,
              child_traces: [],
              tool_calls: [%{name: "echo"} = tool_call]
            }} = Lisp.run("(tool/echo {})", tools: %{"echo" => {tool, :skip}})

    refute Map.has_key?(tool_call, :child_trace_id)
    assert_received :tool_called
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

  test "tool argument normalization scans keyword values nested in ordinary structs" do
    parent = self()

    tool = fn args ->
      send(parent, {:struct_keyword_args, args})
      :ok
    end

    assert {:ok, %{return: :ok}} =
             Lisp.run_native("(tool/echo {:payload data/result})",
               context: %{"result" => %Result{return: Keyword.new("novel")}},
               tools: %{"echo" => {tool, "(payload :any) -> :any"}}
             )

    assert_receive {:struct_keyword_args, %{"payload" => %Result{return: "novel"}}}
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
