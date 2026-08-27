defmodule Mix.Tasks.Ptc.GenDocsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ptc.GenDocs
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.LimitCatalog

  test "generated function reference explains the PtcRunner extension marker" do
    reference = File.read!("docs/function-reference.md")

    assert reference =~ ~r/`[^`]+` \*/
    assert reference =~ "`*` marks PtcRunner extensions without a `clojure.core` equivalent."
  end

  test "generated Kernel limits reference contains every catalog row" do
    reference = File.read!("docs/kernel-limits-reference.md")

    for row <- LimitCatalog.rows() do
      assert reference =~ "`#{row.name}`"
      assert reference =~ row.description
    end
  end

  test "generated prelude reference covers every shipped component and excludes private helpers" do
    reference = File.read!("docs/prelude-reference.md")
    {:ok, components} = Library.components(Library.component_ids())
    {:ok, bundle} = PtcRunner.Kernel.compile_bundle(components)

    for id <- Library.component_ids() do
      assert reference =~ "### `#{id}`"
      assert reference =~ ~s({"library": "#{id}"})
    end

    for export <- bundle.prelude.exports do
      assert reference =~ "##### `#{export.ref}`"
    end

    assert reference =~ "Selecting it also installs"
    assert reference =~ "Directly used by"
    assert reference =~ "Reserved Kernel operations"

    assert reference =~
             "- **Selecting it also installs:** `agent.core`, `agent.failure`, `agent.feedback`, `agent.machine`, `agent.native`, `agent.prompt`, `agent.retry`, `kernel`, `llm`, `result`, `workflow.event`"

    assert reference =~ ~r/##### `llm\/request`.*?- \*\*Effect:\*\* `unknown`/s
    refute reference =~ "agent.feedback/cap-with-marker"
    refute reference =~ "agent.core/run-outcome*"
  end

  @tag :tmp_dir
  test "generated schema inventory reports missing and orphaned PTC schemas", %{tmp_dir: dir} do
    schema_dir = Path.join(dir, "priv/schemas")
    File.mkdir_p!(schema_dir)
    current = Path.join(schema_dir, "ptc-current.schema.json")
    orphan = Path.join(schema_dir, "ptc-orphan.schema.json")
    File.write!(current, "{}")
    File.write!(orphan, "{}")

    discovered = GenDocs.generated_schema_paths(dir)

    assert GenDocs.generated_path_drift([current], discovered) == %{
             missing: [],
             orphaned: [orphan]
           }

    assert GenDocs.generated_path_drift([Path.join(schema_dir, "ptc-missing.schema.json")], []) ==
             %{
               missing: [Path.join(schema_dir, "ptc-missing.schema.json")],
               orphaned: []
             }
  end
end
