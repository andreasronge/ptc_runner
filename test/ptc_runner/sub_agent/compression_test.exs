defmodule PtcRunner.SubAgent.CompressionTest do
  use ExUnit.Case, async: true
  doctest PtcRunner.SubAgent.Compression

  alias PtcRunner.SubAgent.Compression

  describe "normalize/1" do
    test "nil returns {nil, []}" do
      assert Compression.normalize(nil) == {nil, []}
    end

    test "false returns {nil, []}" do
      assert Compression.normalize(false) == {nil, []}
    end

    test "true returns {SingleUserCoalesced, default_opts}" do
      {strategy, opts} = Compression.normalize(true)

      assert strategy == PtcRunner.SubAgent.Compression.SingleUserCoalesced
      assert opts[:println_limit] == 15
      assert opts[:tool_call_limit] == 20
    end

    test "module atom returns {Module, default_opts}" do
      {strategy, opts} = Compression.normalize(SomeCustomStrategy)

      assert strategy == SomeCustomStrategy
      assert opts[:println_limit] == 15
      assert opts[:tool_call_limit] == 20
    end

    test "{Module, opts} merges with defaults" do
      {strategy, opts} = Compression.normalize({MyStrategy, println_limit: 5})

      assert strategy == MyStrategy
      assert opts[:println_limit] == 5
      assert opts[:tool_call_limit] == 20
    end

    test "{Module, opts} can override all defaults" do
      {strategy, opts} =
        Compression.normalize({MyStrategy, println_limit: 10, tool_call_limit: 30})

      assert strategy == MyStrategy
      assert opts[:println_limit] == 10
      assert opts[:tool_call_limit] == 30
    end

    test "{Module, opts} can add custom options" do
      {strategy, opts} = Compression.normalize({MyStrategy, custom_opt: :value})

      assert strategy == MyStrategy
      assert opts[:custom_opt] == :value
      assert opts[:println_limit] == 15
    end
  end

  describe "default_opts/0" do
    test "returns default options" do
      opts = Compression.default_opts()

      assert opts[:println_limit] == 15
      assert opts[:tool_call_limit] == 20
    end
  end
end
