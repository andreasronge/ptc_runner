defmodule PtcRunner.Lisp.Prelude.BundleTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Bundle
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.ValidationError
  alias PtcRunner.Step

  @math_source """
  (ns mathx "Math helpers.")

  (defn add-one [x] (+ x 1))
  """

  @text_source """
  (ns textx "Text helpers.")

  (defn shout [x] (str x "!"))
  """

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
               version: nil,
               checksum: source_hash(@math_source),
               source_hash: source_hash(@math_source),
               namespaces: ["mathx"],
               origin: "file:priv/math.clj"
             },
             %{
               id: "text",
               version: nil,
               checksum: source_hash(@text_source),
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

  test "rejects supplied component checksums that do not match source" do
    assert {:error, %ValidationError{} = error} =
             Bundle.compile([
               %{id: "math", source: @math_source, checksum: "fake"}
             ])

    assert error.reason == :compile_error
    assert error.message =~ "does not match source hash"
  end

  test "compiles precompiled source components into one aggregate artifact" do
    {:ok, math} = Compiler.compile(@math_source)
    {:ok, text} = Compiler.compile(@text_source)

    assert {:ok, %Prelude{} = prelude} =
             Bundle.compile_precompiled([
               %{id: "math", source: @math_source, prelude: math, origin: {:file, "math.clj"}},
               %{id: "text", source: @text_source, prelude: text, origin: :memory}
             ])

    assert prelude.namespaces == ["mathx", "textx"]
    assert {:ok, _} = Prelude.fetch_export(prelude, "mathx/add-one")
    assert {:ok, _} = Prelude.fetch_export(prelude, "textx/shout")

    assert Prelude.trace_summary(prelude).components == [
             %{
               id: "math",
               version: nil,
               checksum: math.source_hash,
               source_hash: math.source_hash,
               namespaces: ["mathx"],
               origin: "file:math.clj"
             },
             %{
               id: "text",
               version: nil,
               checksum: text.source_hash,
               source_hash: text.source_hash,
               namespaces: ["textx"],
               origin: "memory"
             }
           ]
  end

  test "precompiled components reject duplicate namespaces and checksum mismatches" do
    other_math = """
    (ns mathx)
    (defn two [] 2)
    """

    {:ok, math} = Compiler.compile(@math_source)
    {:ok, duplicate} = Compiler.compile(other_math)

    assert {:error, %ValidationError{} = duplicate_error} =
             Bundle.compile_precompiled([
               %{id: "first", source: @math_source, prelude: math},
               %{id: "second", source: other_math, prelude: duplicate}
             ])

    assert duplicate_error.reason == :invalid_namespace
    assert duplicate_error.message =~ "declared by more than one selected prelude"

    assert {:error, %ValidationError{} = checksum_error} =
             Bundle.compile_precompiled([
               %{id: "math", source: @math_source, prelude: math, checksum: "fake"}
             ])

    assert checksum_error.reason == :compile_error
    assert checksum_error.message =~ "does not match source hash"
  end

  test "precompiled components reject source and compiled artifact mismatches" do
    {:ok, math} = Compiler.compile(@math_source)

    assert {:error, %ValidationError{} = error} =
             Bundle.compile_precompiled([
               %{id: "math", source: @text_source, prelude: math}
             ])

    assert error.reason == :compile_error
    assert error.message =~ "source hash"
    assert error.message =~ "compiled source hash"
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
