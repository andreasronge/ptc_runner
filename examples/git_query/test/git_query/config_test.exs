defmodule GitQuery.ConfigTest do
  use ExUnit.Case, async: true

  alias GitQuery.Config

  describe "preset/1" do
    test "returns simple preset" do
      config = Config.preset(:simple)

      assert config.planning == :never
      assert config.context_mode == :all
      assert config.max_turns == 3
      assert config.anchor_mode == :full
    end

    test "returns planned preset" do
      config = Config.preset(:planned)

      assert config.planning == :always
      assert config.context_mode == :declared
      assert config.max_turns == 3
      assert config.anchor_mode == :full
    end

    test "returns adaptive preset" do
      config = Config.preset(:adaptive)

      assert config.planning == :auto
      assert config.context_mode == :declared
      assert config.max_turns == 3
      assert config.anchor_mode == :constraints
    end

    test "returns multi_turn preset" do
      config = Config.preset(:multi_turn)

      assert config.planning == :auto
      assert config.context_mode == :all
      assert config.max_turns == 3
      assert config.anchor_mode == :full
    end
  end

  describe "preset_names/0" do
    test "returns all preset names" do
      names = Config.preset_names()

      assert :simple in names
      assert :planned in names
      assert :adaptive in names
      assert :multi_turn in names
      assert length(names) == 4
    end
  end
end
