defmodule Alma.Environments.ALFWorld.PortTest do
  use ExUnit.Case, async: true

  alias Alma.Environments.ALFWorld.Port, as: AlfPort

  @mock_bridge Path.join([__DIR__, "support", "mock_alfworld_bridge.py"])

  defp start_mock_port do
    {:ok, pid} = AlfPort.start_link(bridge_script: @mock_bridge)
    pid
  end

  describe "init command" do
    test "returns task count" do
      pid = start_mock_port()

      try do
        assert {:ok, %{"status" => "ok", "task_count" => 3}} =
                 AlfPort.command(pid, %{cmd: "init"})
      after
        AlfPort.stop(pid)
      end
    end
  end

  describe "list_tasks command" do
    test "returns list of game files" do
      pid = start_mock_port()

      try do
        {:ok, _} = AlfPort.command(pid, %{cmd: "init"})
        {:ok, response} = AlfPort.command(pid, %{cmd: "list_tasks"})

        assert is_list(response["tasks"])
        assert length(response["tasks"]) == 3
        assert "path/to/task1.tw-pddl" in response["tasks"]
      after
        AlfPort.stop(pid)
      end
    end
  end

  describe "reset command" do
    test "returns initial observation with admissible commands" do
      pid = start_mock_port()

      try do
        {:ok, _} = AlfPort.command(pid, %{cmd: "init"})

        {:ok, response} =
          AlfPort.command(pid, %{cmd: "reset", game_file: "path/to/task1.tw-pddl"})

        assert is_binary(response["obs"])
        assert String.contains?(response["obs"], "desk 1")
        assert is_list(response["admissible_commands"])
        assert "go to desk 1" in response["admissible_commands"]
        assert is_binary(response["goal"])
        assert response["done"] == false
        assert response["score"] == 0
      after
        AlfPort.stop(pid)
      end
    end
  end

  describe "step command" do
    test "returns observation for valid action" do
      pid = start_mock_port()

      try do
        {:ok, _} = AlfPort.command(pid, %{cmd: "init"})
        {:ok, _} = AlfPort.command(pid, %{cmd: "reset", game_file: "path/to/task1.tw-pddl"})

        {:ok, response} = AlfPort.command(pid, %{cmd: "step", action: "go to desk 1"})

        assert String.contains?(response["obs"], "mug 1")
        assert "take mug 1 from desk 1" in response["admissible_commands"]
        assert response["done"] == false
      after
        AlfPort.stop(pid)
      end
    end

    test "returns done=true and score=1 on task completion" do
      pid = start_mock_port()

      try do
        {:ok, _} = AlfPort.command(pid, %{cmd: "init"})
        {:ok, _} = AlfPort.command(pid, %{cmd: "reset", game_file: "path/to/task1.tw-pddl"})
        {:ok, _} = AlfPort.command(pid, %{cmd: "step", action: "go to desk 1"})
        {:ok, _} = AlfPort.command(pid, %{cmd: "step", action: "take mug 1 from desk 1"})
        {:ok, _} = AlfPort.command(pid, %{cmd: "step", action: "go to shelf 1"})
        {:ok, response} = AlfPort.command(pid, %{cmd: "step", action: "put mug 1 in/on shelf 1"})

        assert response["done"] == true
        assert response["score"] == 1
      after
        AlfPort.stop(pid)
      end
    end

    test "returns default response for unknown action" do
      pid = start_mock_port()

      try do
        {:ok, _} = AlfPort.command(pid, %{cmd: "init"})
        {:ok, _} = AlfPort.command(pid, %{cmd: "reset", game_file: "path/to/task1.tw-pddl"})
        {:ok, response} = AlfPort.command(pid, %{cmd: "step", action: "fly to moon"})

        assert response["obs"] == "Nothing happens."
        assert response["done"] == false
      after
        AlfPort.stop(pid)
      end
    end
  end

  describe "full episode via ALFWorld module" do
    alias Alma.Environments.ALFWorld

    test "reset and step through the environment module" do
      pid = start_mock_port()

      try do
        {:ok, _} = AlfPort.command(pid, %{cmd: "init"})

        config = %{
          port_pid: pid,
          game_file: "path/to/task1.tw-pddl"
        }

        state = ALFWorld.reset(config)
        assert is_binary(state.obs)
        assert is_list(state.admissible_commands)
        refute ALFWorld.success?(state)

        obs = ALFWorld.observe(state)
        assert Map.has_key?(obs, :obs)
        assert Map.has_key?(obs, :admissible_commands)
        assert Map.has_key?(obs, :goal)

        # Step through the episode
        {_result, state} = ALFWorld.step(state, "go to desk 1")
        refute ALFWorld.success?(state)

        {_result, state} = ALFWorld.step(state, "take mug 1 from desk 1")
        refute ALFWorld.success?(state)

        {_result, state} = ALFWorld.step(state, "go to shelf 1")
        refute ALFWorld.success?(state)

        {_result, state} = ALFWorld.step(state, "put mug 1 in/on shelf 1")
        assert ALFWorld.success?(state)
        assert state.steps == 4
      after
        AlfPort.stop(pid)
      end
    end

    test "generate_tasks returns tasks from the port" do
      pid = start_mock_port()

      try do
        {:ok, _} = AlfPort.command(pid, %{cmd: "init"})

        tasks = ALFWorld.generate_tasks(2, %{port_pid: pid, seed: 42})
        assert length(tasks) == 2

        for task <- tasks do
          assert is_binary(task.game_file)
          assert task.port_pid == pid
          assert is_map(task.goal)
        end
      after
        AlfPort.stop(pid)
      end
    end
  end

  describe "shutdown" do
    test "stop/1 gracefully shuts down the port" do
      pid = start_mock_port()
      assert Process.alive?(pid)

      ref = Process.monitor(pid)
      AlfPort.stop(pid)

      # Wait for the GenServer to actually terminate (uses a 2s force_close timer)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5000
      refute Process.alive?(pid)
    end
  end
end
