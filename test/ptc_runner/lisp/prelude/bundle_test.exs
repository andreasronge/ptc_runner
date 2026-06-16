defmodule PtcRunner.Lisp.Prelude.BundleTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Bundle
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
