defmodule PtcRunner.Kernel.ServingTemplateMatrixTest do
  use ExUnit.Case,
    async: true,
    parameterize:
      for(
        declared <- [:read, :write, :unknown, nil],
        resolved <- [:read, :write, :unknown],
        do: %{declared: declared, resolved: resolved}
      )

  import PtcRunner.TestSupport.ServingTemplateHelpers

  @moduletag :tmp_dir

  test "the entry matrix includes every selectable mission", %{
    tmp_dir: dir,
    declared: declared,
    resolved: resolved
  } do
    metadata = if declared, do: "{:effect :#{declared}}", else: ""
    workflow = "(ns app) (defn run #{metadata} [input] (return input))"
    mission = "(ns mission) (defn helper {:effect :#{resolved}} [x] x)"

    path =
      fixture(
        dir,
        %{
          "missions" => %{
            "worker" => %{"components" => [%{"id" => "mission", "path" => "mission.clj"}]}
          }
        },
        workflow
      )

    File.write!(Path.join(dir, "mission.clj"), mission)

    case {declared, resolved} do
      {:read, :read} -> assert {:ok, %{effect: :read}} = build(path)
      {:read, _} -> assert {:error, :declared_read_effect_violation} = build(path)
      {:write, _} -> assert {:ok, %{effect: :write}} = build(path)
      _ -> assert {:error, :effect_declaration_required} = build(path)
    end
  end
end
