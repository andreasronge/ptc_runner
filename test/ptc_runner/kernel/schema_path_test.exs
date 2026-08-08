defmodule PtcRunner.Kernel.SchemaPathTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.SchemaPath

  @adversarial ["__proto__", "constructor", "", "properties", "items", "oneOf", "../escape"]

  test "a segment the schema does not define is dropped along with everything after it" do
    assert SchemaPath.explained_prefix(["install", "__proto__", "workspace"], HostConfig.schema()) ==
             [{:property, "install"}]

    assert SchemaPath.explained_prefix(["__proto__"], HostConfig.schema()) == []
    assert SchemaPath.explained_prefix([], HostConfig.schema()) == []
  end

  test "an index is retained only where the schema declares an array" do
    schema = %{"properties" => %{"tags" => %{"items" => %{"type" => "string"}}}}

    assert SchemaPath.explained_prefix(["tags", 2], schema) ==
             [{:property, "tags"}, {:index, 2}]

    assert SchemaPath.explained_prefix(["tags", "2"], schema) == [{:property, "tags"}]
  end

  test "a oneOf is resolved through the branch that defines the segment" do
    schema = %{
      "properties" => %{
        "transport" => %{
          "oneOf" => [
            %{"properties" => %{"command" => %{"type" => "string"}}},
            %{"properties" => %{"url" => %{"type" => "string"}}}
          ]
        }
      }
    }

    assert SchemaPath.explained_prefix(["transport", "url"], schema) ==
             [{:property, "transport"}, {:property, "url"}]

    assert SchemaPath.explained_prefix(["transport", "nope"], schema) ==
             [{:property, "transport"}]
  end

  # The contract the three call sites depend on: whatever prefix survives the
  # walk is a path CommandPath will authorize against the same schema. If the
  # two walkers ever disagree about the schema grammar, this fails.
  test "every explained prefix is a path CommandPath authorizes for that schema" do
    for {label, schema, mint} <- [
          {"host", HostConfig.schema(), &CommandPath.host/1},
          {"manifest", Manifest.schema(), &CommandPath.manifest/1},
          {"component_override", ComponentOverride.schema(), &CommandPath.component_override/1}
        ] do
      explained = document_paths(schema, 4)
      truncating = for path <- explained, junk <- @adversarial, do: path ++ [junk]

      for path <- explained ++ truncating do
        prefix = SchemaPath.explained_prefix(path, schema)

        assert {:ok, %CommandPath{segments: ^prefix}} = mint.(prefix),
               "#{label}: #{inspect(prefix)} from #{inspect(path)} is not schema-authorized"
      end

      # Guard the generator: a schema shape it stopped following would make the
      # assertions above pass vacuously. Depths differ by schema — the host
      # tops out at two segments because installations hang off
      # `additionalProperties`, which is deliberately not traversed.
      deep = Enum.count(explained, &(length(&1) >= 2))

      assert deep >= div(length(explained), 2),
             "#{label}: only #{deep} of #{length(explained)} generated paths are multi-segment"
    end
  end

  # Raw document paths the schema explains: property names as binaries, array
  # indices as integers, every oneOf branch followed.
  defp document_paths(_schema, 0), do: []

  defp document_paths(%{"properties" => properties}, depth) when is_map(properties) do
    Enum.flat_map(properties, fn {name, child} ->
      [[name] | Enum.map(document_paths(child, depth - 1), &[name | &1])]
    end)
  end

  defp document_paths(%{"items" => items}, depth),
    do: [[0] | Enum.map(document_paths(items, depth - 1), &[0 | &1])]

  defp document_paths(%{"oneOf" => branches}, depth) when is_list(branches),
    do: Enum.flat_map(branches, &document_paths(&1, depth))

  defp document_paths(_schema, _depth), do: []
end
