defmodule Mix.Tasks.Ptc.GenDocsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ptc.GenDocs

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
