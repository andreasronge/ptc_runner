defmodule PtcRunner.Kernel.NamedMissionsManifestTest do
  @moduledoc """
  Named missions declared in the manifest, with per-mission provider grants.

  The point of the per-mission grant is negative authority: the reviewer mission is
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

  test "each mission records only the provider occurrences it named" do
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

  test "a mission may name no providers at all" do
    assert {:ok, manifest} =
             load(%{
               "review" => %{
                 "components" => [%{"id" => "r", "path" => "reader.clj"}],
                 "providers" => []
               }
             })

    assert manifest.missions["review"].provider_occurrences == []
  end

  test "a mission cannot name a provider the run never selected" do
    assert {:error, error} =
             load(%{
               "review" => %{
                 "components" => [%{"id" => "r", "path" => "reader.clj"}],
                 "providers" => ["not_selected"]
               }
             })

    assert {:manifest_path, _path, :unknown_mission_provider} = error
  end

  test "mission structure is rejected before any referenced source is read" do
    base = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app.main", "path" => "missing-main.clj"}],
        "entry" => "app.main/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{"mission" => [%{"name" => "reader"}]}
    }

    too_many =
      Map.put(
        base,
        "missions",
        Map.new(1..17, fn index -> {"mission-#{index}", %{}} end)
      )

    assert {:error, {:manifest_path, [{:property, "missions"}], :invalid_missions_manifest}} =
             Manifest.load_memory(
               "ptc.json",
               %{"ptc.json" => Jason.encode!(too_many)},
               Limits.installed_defaults()
             )

    unknown_provider =
      Map.put(base, "missions", %{
        "review" => %{
          "components" => [%{"id" => "review.api", "path" => "missing-review.clj"}],
          "providers" => ["writer"]
        }
      })

    assert {:error, {:manifest_path, _path, :unknown_mission_provider}} =
             Manifest.load_memory(
               "ptc.json",
               %{"ptc.json" => Jason.encode!(unknown_provider)},
               Limits.installed_defaults()
             )
  end

  test "default is an ordinary explicit mission name" do
    assert {:ok, manifest} =
             load(%{"default" => %{"components" => [%{"id" => "r", "path" => "reader.clj"}]}})

    assert [component] = manifest.missions["default"].components
    assert component.id == "r"
  end

  test "each mission compiles its own components" do
    assert {:ok, manifest} =
             load(%{
               "writing" => %{"components" => [%{"id" => "w", "path" => "writer.clj"}]},
               "review" => %{"components" => [%{"id" => "r", "path" => "reader.clj"}]}
             })

    ids = fn space -> Enum.map(manifest.missions[space].components, & &1.id) end
    assert ids.("writing") == ["w"]
    assert ids.("review") == ["r"]
  end

  test "omitting missions declares no missions" do
    assert {:ok, manifest} = load(%{})
    assert manifest.missions == %{}
  end

  test "the removed singular mission key is rejected" do
    documents = manifest_documents(%{})
    manifest = documents["ptc.json"] |> Jason.decode!() |> Map.put("mission", %{})

    assert {:error, :unknown_properties} =
             Manifest.load_memory(
               "ptc.json",
               Map.put(documents, "ptc.json", Jason.encode!(manifest)),
               Limits.installed_defaults()
             )
  end

  test "provider grants are unique and bounded" do
    assert {:error, {:manifest_path, _, :duplicate_mission_provider}} =
             load(%{"review" => %{"providers" => ["reader_tool", "reader_tool"]}})
  end

  test "component occurrences are bounded across all missions before source reads" do
    component = %{"id" => "r", "path" => "missing.clj"}
    missions = Map.new(1..16, &{"m#{&1}", %{"components" => List.duplicate(component, 9)}})

    assert {:error, {:manifest_path, _, :mission_aggregate_limit_exceeded}} = load(missions)
  end
end
