defmodule PtcRunner.Lisp.Prelude.BundleTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Bundle
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.ValidationError
  alias PtcRunner.Lisp.Result, as: Step

  @math_source """
  (ns mathx "Math helpers.")

  (defn add-one [x] (+ x 1))
  """

  @text_source """
  (ns textx "Text helpers.")

  (defn shout [x] (str x "!"))
  """

  test "trace artifact hash changes with enforced export contracts" do
    {:ok, int_function} =
      Compiler.compile(~S|(ns api) (defn id {:signature "(value :int) -> :int"} [value] value)|)

    {:ok, string_function} =
      Compiler.compile(
        ~S|(ns api) (defn id {:signature "(value :string) -> :string"} [value] value)|
      )

    {:ok, int_constant} = Compiler.compile(~S|(ns api) (def answer {:type ":int"} 42)|)
    {:ok, string_constant} = Compiler.compile(~S|(ns api) (def answer {:type ":string"} "42")|)

    int_function_trace = Prelude.trace_summary(int_function)
    string_function_trace = Prelude.trace_summary(string_function)
    int_constant_trace = Prelude.trace_summary(int_constant)
    string_constant_trace = Prelude.trace_summary(string_constant)

    assert [%{signature: "(value :int) -> :int", type: nil}] = int_function_trace.exports
    assert [%{signature: nil, type: ":int"}] = int_constant_trace.exports
    refute int_function_trace.artifact_hash == string_function_trace.artifact_hash
    refute int_constant_trace.artifact_hash == string_constant_trace.artifact_hash
  end

  test "compiles selected source components once into a normal prelude artifact" do
    assert {:ok, %Prelude{} = prelude} =
             Bundle.compile([
               %{id: "math", source: @math_source, origin: {:file, "priv/math.clj"}},
               %{id: "text", source: @text_source, origin: :memory}
             ])

    assert prelude.namespaces == ["mathx", "textx"]
    assert {:ok, _} = Prelude.fetch_export(prelude, "mathx/add-one")
    assert {:ok, _} = Prelude.fetch_export(prelude, "textx/shout")

    assert Prelude.trace_summary(prelude).components == [
             %{
               id: "math",
               source_hash: source_hash(@math_source),
               namespaces: ["mathx"],
               origin: "file:priv/math.clj"
             },
             %{
               id: "text",
               source_hash: source_hash(@text_source),
               namespaces: ["textx"],
               origin: "memory"
             }
           ]
  end

  test "rejects duplicate namespaces before concatenated compile" do
    other_math = """
    (ns mathx)
    (defn two [] 2)
    """

    assert {:error, %ValidationError{} = error} =
             Bundle.compile([
               %{id: "first", source: @math_source},
               %{id: "second", source: other_math}
             ])

    assert error.reason == :invalid_namespace
    assert error.namespace == "mathx"
    assert error.message =~ "declared by more than one selected prelude"
  end

  test "rejects fields outside the current source selection contract" do
    assert {:error, %ValidationError{} = error} =
             Bundle.compile([%{id: "math", source: @math_source, version: 1}])

    assert error.message ==
             "prelude bundle selection contains unsupported or duplicate fields"
  end

  test "Lisp.run accepts a list of selected prelude sources" do
    assert {:ok, %Step{} = step} =
             PtcRunner.Lisp.run(~S|(return [(mathx/add-one 2) (textx/shout "ok")])|,
               prelude: [
                 %{id: "math", source: @math_source},
                 %{id: "text", source: @text_source}
               ]
             )

    assert step.return == {:__ptc_return__, [3, "ok!"]}
    assert step.prelude_trace.protected_namespaces == ["mathx", "textx"]
    assert Enum.map(step.prelude_trace.components, & &1.id) == ["math", "text"]
  end

  defp source_hash(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end
end
