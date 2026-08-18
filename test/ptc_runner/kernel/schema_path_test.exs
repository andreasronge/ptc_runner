defmodule PtcRunner.Kernel.SchemaPathTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.SchemaPath

  @adversarial ["__proto__", "constructor", "", "properties", "items", "oneOf", "../escape"]

  test "a segment the schema does not define is dropped along with everything after it" do
    # `__proto__` is a caller-chosen install alias, so it is elided rather than
    # named; `workspace` is not a member of the closed installation schema, so
    # the walk stops there.
    assert SchemaPath.explained_prefix(["install", "__proto__", "workspace"], HostConfig.schema()) ==
             [{:property, "install"}, {:property, "*"}]

    assert SchemaPath.explained_prefix(["__proto__"], HostConfig.schema()) == []
    assert SchemaPath.explained_prefix([], HostConfig.schema()) == []
  end

  # `install` is an open map keyed by a caller-chosen alias, but everything
  # beneath one installation is a closed schema. Stopping at `install` reported
  # the same pointer for a bad `ceilings` key, an out-of-range
  # `transport.start_timeout_ms`, and a missing `tools` block.
  test "a caller-chosen member is elided and the closed schema beneath it keeps walking" do
    assert SchemaPath.explained_prefix(
             ["install", "my-llm", "ceilings", "timeout_ms"],
             HostConfig.schema()
           ) ==
             [
               {:property, "install"},
               {:property, "*"},
               {:property, "ceilings"},
               {:property, "timeout_ms"}
             ]

    assert SchemaPath.explained_prefix(
             ["install", "gh", "transport", "start_timeout_ms"],
             HostConfig.schema()
           ) ==
             [
               {:property, "install"},
               {:property, "*"},
               {:property, "transport"},
               {:property, "start_timeout_ms"}
             ]

    # The alias itself never reaches the pointer, and a segment the closed
    # schema beneath it cannot explain still truncates there.
    assert SchemaPath.explained_prefix(
             ["install", "my-llm", "evaluation_timeout_ms"],
             HostConfig.schema()
           ) == [{:property, "install"}, {:property, "*"}]
  end

  test "a member is elided only where no admissible name could render as the placeholder" do
    # `propertyNames` is what makes the placeholder unambiguous. A map that
    # admits `*` itself gets no elision, because a pointer that could mean two
    # different members is worse than one that stops short.
    for open <- open_maps(HostConfig.schema(), 6) do
      pattern = get_in(open, ["propertyNames", "pattern"])
      admits_placeholder? = is_binary(pattern) and Regex.match?(Regex.compile!(pattern), "*")

      assert match?({:ok, _child}, CommandPath.elidable_child(open)) == not admits_placeholder?
    end

    # The two live cases, stated outright: an installation alias is elided, an
    # upstream tool name is not.
    assert SchemaPath.explained_prefix(
             ["install", "gh", "tools", "get_me", "as"],
             HostConfig.schema()
           ) == [{:property, "install"}, {:property, "*"}, {:property, "tools"}]
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

  # Every schema node that admits caller-chosen member names, at any depth.
  defp open_maps(_schema, 0), do: []

  defp open_maps(%{"additionalProperties" => child} = schema, depth) when is_map(child),
    do: [schema | open_maps(child, depth - 1)]

  defp open_maps(%{"properties" => properties}, depth) when is_map(properties),
    do: properties |> Map.values() |> Enum.flat_map(&open_maps(&1, depth - 1))

  defp open_maps(%{"items" => items}, depth), do: open_maps(items, depth - 1)

  defp open_maps(%{"oneOf" => branches}, depth) when is_list(branches),
    do: Enum.flat_map(branches, &open_maps(&1, depth))

  defp open_maps(_schema, _depth), do: []
end
