defmodule PtcRunner.SubAgent.ExposureTest do
  @moduledoc """
  Tier 1a: validates the `expose:` / `native_result:` tool-metadata
  contract and the `PtcRunner.SubAgent.Exposure` helpers.

  Covers:
    - validator acceptance/rejection of `expose:` values
    - validator acceptance/rejection of `native_result:` cross-field rules
    - `Exposure.effective_expose/2` per-mode defaults
    - `Exposure.filter_by_expose/3` filtering semantics
  """

  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Exposure
  alias PtcRunner.Tool

  doctest PtcRunner.SubAgent.Exposure

  # Stable function for `native_result.preview:` custom-function tests.
  # Public so `&__MODULE__.custom_preview/1` resolves at compile time.
  def custom_preview(_full_result), do: %{}

  # ---------------------------------------------------------------------------
  # `expose:` validation at agent construction
  # ---------------------------------------------------------------------------

  describe "expose: validation" do
    for value <- [:native, :ptc_lisp, :both] do
      test "accepts expose: #{inspect(value)}" do
        tools = %{"t" => {fn _ -> :ok end, [signature: "() -> :string", expose: unquote(value)]}}

        agent = SubAgent.new(prompt: "Test", tools: tools)
        assert agent.tools == tools
      end
    end

    test "accepts missing expose: (mode default applied later by helper)" do
      tools = %{"t" => {fn _ -> :ok end, [signature: "() -> :string"]}}

      agent = SubAgent.new(prompt: "Test", tools: tools)
      assert agent.tools == tools
    end

    test "rejects an unknown atom and names the tool + accepted values" do
      tools = %{"oops" => {fn _ -> :ok end, [signature: "() -> :string", expose: :wrong]}}

      assert_raise ArgumentError,
                   ~r/tool "oops".*expose.*:wrong.*:native.*:ptc_lisp.*:both/,
                   fn -> SubAgent.new(prompt: "Test", tools: tools) end
    end

    test "rejects a non-atom value" do
      tools = %{"oops" => {fn _ -> :ok end, [signature: "() -> :string", expose: "native"]}}

      assert_raise ArgumentError, ~r/tool "oops".*expose/, fn ->
        SubAgent.new(prompt: "Test", tools: tools)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # `native_result:` cross-field validation
  # ---------------------------------------------------------------------------

  describe "native_result: cross-field validation" do
    test "rejects native_result: when expose: is :native" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :native,
             cache: true,
             native_result: [preview: :metadata]
           ]}
      }

      assert_raise ArgumentError,
                   ~r/tool "t".*native_result.*expose.*cache/,
                   fn -> SubAgent.new(prompt: "Test", tools: tools) end
    end

    test "rejects native_result: when expose: is :ptc_lisp" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :ptc_lisp,
             cache: true,
             native_result: [preview: :metadata]
           ]}
      }

      assert_raise ArgumentError,
                   ~r/tool "t".*native_result.*expose.*cache/,
                   fn -> SubAgent.new(prompt: "Test", tools: tools) end
    end

    test "rejects native_result: when cache: is false (expose: :both, cache: false)" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :both,
             cache: false,
             native_result: [preview: :metadata]
           ]}
      }

      # Per Implementation Contract: ArgumentError naming both keys.
      assert_raise ArgumentError,
                   ~r/tool "t".*native_result.*expose.*cache/,
                   fn -> SubAgent.new(prompt: "Test", tools: tools) end
    end

    test "rejects native_result: when cache: is omitted (defaults to false)" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :both,
             native_result: [preview: :metadata]
           ]}
      }

      assert_raise ArgumentError,
                   ~r/tool "t".*native_result.*expose.*cache/,
                   fn -> SubAgent.new(prompt: "Test", tools: tools) end
    end

    test "accepts native_result: when expose: :both AND cache: true" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :both,
             cache: true,
             native_result: [preview: :metadata]
           ]}
      }

      agent = SubAgent.new(prompt: "Test", tools: tools)
      assert agent.tools == tools
    end

    test "rejects non-keyword native_result: value" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [signature: "() -> :string", expose: :both, cache: true, native_result: :metadata]}
      }

      assert_raise ArgumentError,
                   ~r/tool "t".*native_result.*keyword list/,
                   fn -> SubAgent.new(prompt: "Test", tools: tools) end
    end

    # Addendum #17 — must be explicitly accepted.
    test "accepts expose: :both, cache: false WITHOUT native_result:" do
      tools = %{
        "t" => {fn _ -> :ok end, [signature: "() -> :string", expose: :both, cache: false]}
      }

      agent = SubAgent.new(prompt: "Test", tools: tools)
      assert agent.tools == tools
    end
  end

  # ---------------------------------------------------------------------------
  # `native_result.preview:` shape validation
  # ---------------------------------------------------------------------------

  describe "native_result.preview: validation" do
    for value <- [:metadata, :rows] do
      test "accepts preview: #{inspect(value)}" do
        tools = %{
          "t" =>
            {fn _ -> :ok end,
             [
               signature: "() -> :string",
               expose: :both,
               cache: true,
               native_result: [preview: unquote(value)]
             ]}
        }

        agent = SubAgent.new(prompt: "Test", tools: tools)
        assert agent.tools == tools
      end
    end

    test "accepts a 1-arity function as preview:" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :both,
             cache: true,
             native_result: [preview: &__MODULE__.custom_preview/1]
           ]}
      }

      agent = SubAgent.new(prompt: "Test", tools: tools)
      assert agent.tools == tools
    end

    test "rejects an unknown atom preview:" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :both,
             cache: true,
             native_result: [preview: :wrong]
           ]}
      }

      assert_raise ArgumentError,
                   ~r/tool "t".*preview.*:metadata.*:rows.*1-arity/,
                   fn -> SubAgent.new(prompt: "Test", tools: tools) end
    end

    test "rejects an integer preview:" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :both,
             cache: true,
             native_result: [preview: 7]
           ]}
      }

      assert_raise ArgumentError, ~r/tool "t".*preview/, fn ->
        SubAgent.new(prompt: "Test", tools: tools)
      end
    end

    test "rejects a 0-arity function preview:" do
      zero_arity = fn -> %{} end

      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :both,
             cache: true,
             native_result: [preview: zero_arity]
           ]}
      }

      assert_raise ArgumentError, ~r/tool "t".*preview/, fn ->
        SubAgent.new(prompt: "Test", tools: tools)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # `native_result.limit:` validation
  # ---------------------------------------------------------------------------

  describe "native_result.limit: validation" do
    test "accepts a positive integer limit" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :both,
             cache: true,
             native_result: [preview: :rows, limit: 50]
           ]}
      }

      agent = SubAgent.new(prompt: "Test", tools: tools)
      assert agent.tools == tools
    end

    test "rejects zero limit" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :both,
             cache: true,
             native_result: [preview: :rows, limit: 0]
           ]}
      }

      assert_raise ArgumentError, ~r/tool "t".*limit.*positive integer/, fn ->
        SubAgent.new(prompt: "Test", tools: tools)
      end
    end

    test "rejects negative limit" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :both,
             cache: true,
             native_result: [preview: :rows, limit: -1]
           ]}
      }

      assert_raise ArgumentError, ~r/tool "t".*limit/, fn ->
        SubAgent.new(prompt: "Test", tools: tools)
      end
    end

    test "rejects non-integer limit" do
      tools = %{
        "t" =>
          {fn _ -> :ok end,
           [
             signature: "() -> :string",
             expose: :both,
             cache: true,
             native_result: [preview: :rows, limit: "10"]
           ]}
      }

      assert_raise ArgumentError, ~r/tool "t".*limit/, fn ->
        SubAgent.new(prompt: "Test", tools: tools)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # `effective_expose/2` defaults per mode
  # ---------------------------------------------------------------------------

  describe "effective_expose/2 mode defaults" do
    test "text + non-tool_call transport defaults to :native" do
      tool = %Tool{name: "t", expose: nil}
      assert Exposure.effective_expose(tool, {:text, nil}) == :native
      assert Exposure.effective_expose(tool, {:text, :content}) == :native
    end

    test "combined mode (text + :tool_call) defaults to :native" do
      tool = %Tool{name: "t", expose: nil}
      assert Exposure.effective_expose(tool, {:text, :tool_call}) == :native
    end

    test ":ptc_lisp output mode defaults to :ptc_lisp regardless of transport" do
      tool = %Tool{name: "t", expose: nil}
      assert Exposure.effective_expose(tool, {:ptc_lisp, :content}) == :ptc_lisp
      assert Exposure.effective_expose(tool, {:ptc_lisp, :tool_call}) == :ptc_lisp
    end

    test "explicit expose: overrides any mode default" do
      assert Exposure.effective_expose(%Tool{name: "t", expose: :ptc_lisp}, {:text, nil}) ==
               :ptc_lisp

      assert Exposure.effective_expose(%Tool{name: "t", expose: :native}, {:ptc_lisp, :content}) ==
               :native

      assert Exposure.effective_expose(%Tool{name: "t", expose: :both}, {:text, :tool_call}) ==
               :both
    end

    test "accepts a Definition-shaped struct" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :ptc_lisp,
          ptc_transport: :tool_call
        )

      tool = %Tool{name: "t", expose: nil}
      assert Exposure.effective_expose(tool, agent) == :ptc_lisp
    end
  end

  # ---------------------------------------------------------------------------
  # `filter_by_expose/3`
  # ---------------------------------------------------------------------------

  describe "filter_by_expose/3" do
    setup do
      tools = [
        %Tool{name: "native_only", expose: :native},
        %Tool{name: "ptc_only", expose: :ptc_lisp},
        %Tool{name: "both_layer", expose: :both},
        %Tool{name: "default_text", expose: nil}
      ]

      {:ok, tools: tools}
    end

    test "combined-mode native filter selects [:native, :both] (default tools fall to :native)",
         %{tools: tools} do
      result = Exposure.filter_by_expose(tools, {:text, :tool_call}, [:native, :both])
      assert Enum.map(result, & &1.name) == ["native_only", "both_layer", "default_text"]
    end

    test "PTC-Lisp inventory filter [:ptc_lisp, :both] in combined mode", %{tools: tools} do
      # In combined mode `default_text` (no explicit expose) defaults to
      # :native, so it must be excluded.
      result = Exposure.filter_by_expose(tools, {:text, :tool_call}, [:ptc_lisp, :both])
      assert Enum.map(result, & &1.name) == ["ptc_only", "both_layer"]
    end

    test "PTC-Lisp inventory filter in :ptc_lisp mode includes default tools", %{tools: tools} do
      # In :ptc_lisp mode `default_text` defaults to :ptc_lisp.
      result = Exposure.filter_by_expose(tools, {:ptc_lisp, :content}, [:ptc_lisp, :both])
      assert Enum.map(result, & &1.name) == ["ptc_only", "both_layer", "default_text"]
    end

    test "accepts a MapSet for allowed_set", %{tools: tools} do
      result =
        Exposure.filter_by_expose(tools, {:text, :tool_call}, MapSet.new([:native, :both]))

      assert Enum.map(result, & &1.name) == ["native_only", "both_layer", "default_text"]
    end

    test "accepts a tools map (sorted by name)", %{tools: tools} do
      tools_map = Map.new(tools, &{&1.name, &1})
      result = Exposure.filter_by_expose(tools_map, {:text, :tool_call}, [:native, :both])
      assert Enum.map(result, & &1.name) == ["both_layer", "default_text", "native_only"]
    end

    test "preserves list order", %{tools: tools} do
      reversed = Enum.reverse(tools)
      result = Exposure.filter_by_expose(reversed, {:text, :tool_call}, [:native, :both])
      assert Enum.map(result, & &1.name) == ["default_text", "both_layer", "native_only"]
    end
  end
end
