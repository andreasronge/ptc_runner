defmodule PtcRunner.Kernel.MissionSpacesManifestTest do
  @moduledoc """
  SPIKE: mission spaces declared in the manifest, with per-space provider grants.

  The point of the per-space grant is negative authority: the reviewer space is
  not merely asked to avoid the write tool, it does not have it.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Manifest

  defp manifest_documents(missions) do
    %{
      "ptc.json" =>
        Jason.encode!(%{
          "version" => 1,
          "workflow" => %{
            "components" => [%{"id" => "app.main", "path" => "main.clj"}],
            "entry" => "app.main/run"
          },
          "input" => %{"value" => %{}},
          "providers" => %{
            "mission" => [
              %{"name" => "writer_tool"},
              %{"name" => "reader_tool"}
            ]
          },
          "missions" => missions
        }),
      "main.clj" => "(ns app.main)\n(defn run [_input] (return 1))\n",
      "writer.clj" => "(ns w \"Writer API.\" {:visibility :prompt})\n(defn note [] 1)\n",
      "reader.clj" => "(ns r \"Reader API.\" {:visibility :prompt})\n(defn look [] 2)\n"
    }
    |> drop_unreferenced(missions)
  end

  # load_memory rejects a document the manifest never references.
  defp drop_unreferenced(documents, missions) do
    referenced =
      missions
      |> Map.values()
      |> Enum.flat_map(&Map.get(&1, "components", []))
      |> Enum.map(& &1["path"])

    Map.drop(documents, ["writer.clj", "reader.clj"] -- referenced)
  end

  defp load(missions) do
    Manifest.load_memory("ptc.json", manifest_documents(missions), Limits.installed_defaults())
  end

  test "each space records only the provider occurrences it named" do
    assert {:ok, manifest} =
             load(%{
               "writing" => %{
                 "components" => [%{"id" => "w", "path" => "writer.clj"}],
                 "providers" => ["writer_tool"]
               },
               "review" => %{
                 "components" => [%{"id" => "r", "path" => "reader.clj"}],
                 "providers" => ["reader_tool"]
               }
             })

    # Occurrence 0 is writer_tool, 1 is reader_tool.
    assert manifest.missions["writing"].provider_occurrences == [0]
    assert manifest.missions["review"].provider_occurrences == [1]
  end

  test "a space may name no providers at all" do
    assert {:ok, manifest} =
             load(%{
               "review" => %{
                 "components" => [%{"id" => "r", "path" => "reader.clj"}],
                 "providers" => []
               }
             })

    assert manifest.missions["review"].provider_occurrences == []
  end

  test "a space cannot name a provider the run never selected" do
    assert {:error, error} =
             load(%{
               "review" => %{
                 "components" => [%{"id" => "r", "path" => "reader.clj"}],
                 "providers" => ["not_selected"]
               }
             })

    assert {:manifest_path, _path, :unknown_mission_space_provider} = error
  end

  test "a space cannot be named default" do
    assert {:error, error} =
             load(%{"default" => %{"components" => [%{"id" => "r", "path" => "reader.clj"}]}})

    assert {:manifest_path, _path, :invalid_missions_manifest} = error
  end

  test "each space compiles its own components" do
    assert {:ok, manifest} =
             load(%{
               "writing" => %{"components" => [%{"id" => "w", "path" => "writer.clj"}]},
               "review" => %{"components" => [%{"id" => "r", "path" => "reader.clj"}]}
             })

    ids = fn space -> Enum.map(manifest.missions[space].components, & &1.id) end
    assert ids.("writing") == ["w"]
    assert ids.("review") == ["r"]
  end

  test "omitting missions keeps the singular mission manifest working" do
    assert {:ok, manifest} = load(%{})
    assert manifest.missions == %{}
  end
end
