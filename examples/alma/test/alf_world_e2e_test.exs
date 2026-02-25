defmodule Alma.Environments.ALFWorldE2ETest do
  @moduledoc """
  End-to-end smoke test for ALFWorld environment.

  Requires Python with `alfworld` installed. Run with:

      mix test --include alfworld
  """
  use ExUnit.Case

  alias Alma.Environments.ALFWorld
  alias Alma.Environments.ALFWorld.Port, as: AlfPort

  @tag :alfworld
  test "ALFWorld reset and step through a single episode" do
    python = System.get_env("ALFWORLD_PYTHON", "python3")
    {:ok, port_pid} = AlfPort.start_link(python: python)

    try do
      # Initialize
      {:ok, init_resp} = AlfPort.command(port_pid, %{cmd: "init"})

      if init_resp["status"] == "error" do
        AlfPort.stop(port_pid)
        flunk("ALFWorld init failed: #{init_resp["error"]}. Is alfworld installed?")
      end

      assert init_resp["task_count"] > 0

      # List tasks and pick the first one
      {:ok, %{"tasks" => tasks}} = AlfPort.command(port_pid, %{cmd: "list_tasks"})
      assert length(tasks) > 0

      game_file = hd(tasks)

      # Reset the environment
      config = %{port_pid: port_pid, game_file: game_file}
      state = ALFWorld.reset(config)

      assert is_binary(state.obs)
      assert is_list(state.admissible_commands)
      assert length(state.admissible_commands) > 0
      refute ALFWorld.success?(state)

      # Take one step using the first admissible command
      action = hd(state.admissible_commands)
      {result, new_state} = ALFWorld.step(state, action)

      assert is_binary(result.obs)
      assert is_list(result.admissible_commands)
      assert new_state.steps == 1
    after
      AlfPort.stop(port_pid)
    end
  end
end
