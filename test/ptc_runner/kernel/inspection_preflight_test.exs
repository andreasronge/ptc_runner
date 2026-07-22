defmodule PtcRunner.Kernel.InspectionPreflightTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder

  describe "InspectionArtifact.preflight_destination/1" do
    @tag :tmp_dir
    test "classifies invalid, occupied, unavailable, and free destinations", %{tmp_dir: dir} do
      assert {:error, :invalid_inspection_path} = InspectionArtifact.preflight_destination(42)

      assert {:error, :invalid_inspection_path} =
               InspectionArtifact.preflight_destination(Path.join(dir, "run.jsonl"))

      file = Path.join(dir, "file.inspection.jsonl")
      File.write!(file, "occupied")

      assert {:error, :inspection_destination_exists} =
               InspectionArtifact.preflight_destination(file)

      symlink = Path.join(dir, "link.inspection.jsonl")
      File.ln_s!(file, symlink)

      assert {:error, :inspection_destination_exists} =
               InspectionArtifact.preflight_destination(symlink)

      directory = Path.join(dir, "dir.inspection.jsonl")
      File.mkdir!(directory)

      assert {:error, :inspection_destination_exists} =
               InspectionArtifact.preflight_destination(directory)

      under_file = Path.join(file, "nested.inspection.jsonl")

      assert {:error, :inspection_destination_unavailable} =
               InspectionArtifact.preflight_destination(under_file)

      assert :ok =
               InspectionArtifact.preflight_destination(Path.join(dir, "free.inspection.jsonl"))
    end
  end

  describe "RunBuilder preflight ordering" do
    @tag :tmp_dir
    test "an occupied destination is rejected before any provider builder runs", %{tmp_dir: dir} do
      parent = self()

      builder = fn _config, _context ->
        send(parent, :provider_builder_invoked)
        {:error, :should_not_run}
      end

      {:ok, registry} = ProviderRegistry.new(%{"probe" => builder})

      manifest_path =
        write_manifest(dir, %{"workflow" => [%{"name" => "probe", "config" => %{}}]})

      occupied = Path.join(dir, "run.inspection.jsonl")
      File.write!(occupied, "occupied")

      assert {:error, {:inspection_preflight_failed, :inspection_destination_exists}} =
               RunBuilder.run(manifest_path, registry,
                 trace: Path.join(dir, "run.jsonl"),
                 inspect: occupied
               )

      refute_received :provider_builder_invoked
    end

    @tag :tmp_dir
    test "manifest and input errors take precedence over an occupied destination", %{
      tmp_dir: dir
    } do
      {:ok, registry} = ProviderRegistry.new()
      occupied = Path.join(dir, "run.inspection.jsonl")
      File.write!(occupied, "occupied")

      missing_manifest = Path.join(dir, "absent.json")

      assert {:error, reason} =
               RunBuilder.run(missing_manifest, registry, inspect: occupied)

      refute match?({:inspection_preflight_failed, _reason}, reason)

      manifest_path = write_manifest(dir, %{})

      assert {:error, reason} =
               RunBuilder.run(manifest_path, registry,
                 mission: "absent-override.json",
                 inspect: occupied
               )

      refute match?({:inspection_preflight_failed, _reason}, reason)
    end
  end

  defp write_manifest(dir, providers) do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return 42))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "providers" => providers
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end
end
