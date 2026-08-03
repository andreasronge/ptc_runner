defmodule Mix.Tasks.Ptc.GenSemanticRevisionTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ptc.GenSemanticRevision

  @tag :tmp_dir
  test "audited roots change their projection for file additions and mutations", %{
    tmp_dir: directory
  } do
    root = Path.join(directory, "semantic")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "existing.ex"), "first")
    File.write!(Path.join(directory, "outside.ex"), "outside-first")

    inventory = %{
      semantic_roots: [%{root: "semantic", exclusions: []}],
      semantic_files: ["outside.ex"]
    }

    first = GenSemanticRevision.source_projection(inventory, directory)

    File.write!(Path.join(root, "added.ex"), "added")
    added = GenSemanticRevision.source_projection(inventory, directory)

    File.write!(Path.join(root, "existing.ex"), "changed")
    changed = GenSemanticRevision.source_projection(inventory, directory)

    File.write!(Path.join(directory, "outside.ex"), "outside-changed")
    changed_explicit = GenSemanticRevision.source_projection(inventory, directory)

    refute first["source_closure_hash"] == added["source_closure_hash"]
    refute added["source_closure_hash"] == changed["source_closure_hash"]
    refute changed["source_closure_hash"] == changed_explicit["source_closure_hash"]
    assert Enum.any?(added["sources"], &(&1["path"] == "semantic/added.ex"))
  end

  @tag :tmp_dir
  test "generated launcher artifacts do not perturb a semantic root", %{tmp_dir: directory} do
    root = Path.join(directory, "launcher")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/runtime.ex"), "semantic")

    inventory = %{
      semantic_roots: [
        %{
          root: "launcher",
          exclusions: [
            "launcher/_build",
            "launcher/tmp",
            "launcher/launcher-*.tar"
          ]
        }
      ],
      semantic_files: []
    }

    clean = GenSemanticRevision.source_projection(inventory, directory)

    File.mkdir_p!(Path.join(root, "_build/test"))
    File.mkdir_p!(Path.join(root, "tmp/random"))
    File.write!(Path.join(root, "_build/test/runtime.beam"), "machine-local")
    File.write!(Path.join(root, "tmp/random/sentinel"), "random")
    File.write!(Path.join(root, "launcher-local.tar"), "archive")

    dirty = GenSemanticRevision.source_projection(inventory, directory)
    assert clean == dirty
  end
end
