defmodule GitQuery.PipelineTest do
  use ExUnit.Case

  alias GitQuery.{Config, Tools}

  describe "run/4 with :simple preset" do
    @tag :skip
    test "executes single step without planning" do
      # This test would require a more sophisticated mock LLM setup
      # that can handle the full SubAgent protocol
    end
  end

  describe "integration with real tools" do
    setup do
      # Use the ptc_runner repo for testing
      repo_path = Path.expand("../../../..", __DIR__)
      tools = Tools.build_tools(repo_path)

      {:ok, repo_path: repo_path, tools: tools}
    end

    test "tools are properly configured", %{tools: tools} do
      assert Map.has_key?(tools, "get_commits")
      assert Map.has_key?(tools, "get_author_stats")
      assert Map.has_key?(tools, "get_file_stats")
      assert Map.has_key?(tools, "get_file_history")
      assert Map.has_key?(tools, "get_diff_stats")

      # Each tool should be a tuple with function and options
      for {_name, tool} <- tools do
        assert is_tuple(tool)
        {fun, opts} = tool
        assert is_function(fun, 1)
        assert Keyword.has_key?(opts, :signature)
        assert Keyword.has_key?(opts, :description)
      end
    end
  end

  describe "config preset integration" do
    test "simple preset has correct values" do
      config = Config.preset(:simple)

      assert config.planning == :never
      assert config.context_mode == :all
      assert config.max_turns == 3
      assert config.anchor_mode == :full
    end

    test "adaptive preset has correct values" do
      config = Config.preset(:adaptive)

      assert config.planning == :auto
      assert config.context_mode == :declared
      assert config.max_turns == 3
      assert config.anchor_mode == :constraints
    end
  end
end
