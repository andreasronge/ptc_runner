defmodule PtcViewer.LiveLaunchTest do
  use ExUnit.Case, async: true

  alias PtcViewer.LiveLaunch

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "ptc.json"), "{}")
    %{spec: %{manifest: "ptc.json", cwd: tmp_dir}}
  end

  describe "validate/1" do
    test "accepts a spec carrying separate repl arguments", %{spec: spec} do
      assert :ok = LiveLaunch.validate(Map.put(spec, :repl_args, ["--host-config", "host.json"]))
    end

    test "rejects repl arguments that are not a list of strings", %{spec: spec} do
      assert {:error, :invalid_launch_config} =
               LiveLaunch.validate(Map.put(spec, :repl_args, ["--host-config", :host]))

      assert {:error, :invalid_launch_config} =
               LiveLaunch.validate(Map.put(spec, :repl_args, "--host-config"))
    end
  end

  describe "mission_command/3" do
    test "invokes the mission through the repl command", %{spec: spec} do
      assert LiveLaunch.mission_command(spec, "review", "(dir)") ==
               ["ptc", "repl", "--manifest", "ptc.json", "--mission", "review", "-e", "(dir)"]
    end

    test "inserts the operator's repl arguments, never the run arguments", %{spec: spec} do
      spec =
        spec
        |> Map.put(:args, ["--trace-dir", "traces"])
        |> Map.put(:repl_args, ["--host-config", "host.json"])

      command = LiveLaunch.mission_command(spec, "review", "(dir)")

      assert command == [
               "ptc",
               "repl",
               "--manifest",
               "ptc.json",
               "--host-config",
               "host.json",
               "--mission",
               "review",
               "-e",
               "(dir)"
             ]

      refute "--trace-dir" in command
    end
  end

  describe "prepare_mission/4" do
    test "prepares a run function without invoking it", %{spec: spec} do
      assert {:ok, run} = LiveLaunch.prepare_mission(spec, "review", "(dir)", 4123)
      assert is_function(run, 0)
    end

    test "refuses a mission name that is not a manifest mission name", %{spec: spec} do
      for name <- ["--host-config", "Review", "", "a b", "../escape"] do
        assert {:error, :invalid_mission} = LiveLaunch.prepare_mission(spec, name, "(dir)", 4123)
      end

      assert {:error, :invalid_mission} = LiveLaunch.prepare_mission(spec, :review, "(dir)", 4123)
    end

    test "refuses a blank expression", %{spec: spec} do
      assert {:error, :invalid_mission} = LiveLaunch.prepare_mission(spec, "review", "   ", 4123)
      assert {:error, :invalid_mission} = LiveLaunch.prepare_mission(spec, "review", nil, 4123)
    end

    test "refuses to launch when no usable viewer port is known", %{spec: spec} do
      assert {:error, :launch_not_configured} =
               LiveLaunch.prepare_mission(spec, "review", "(dir)", 0)
    end
  end
end
