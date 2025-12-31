defmodule PtcRunner.SubAgent.PlaceholderTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "new/1 - placeholder validation" do
    test "accepts when placeholders match signature parameters" do
      agent =
        SubAgent.new(
          prompt: "Find {{user}} emails with {{limit}}",
          signature: "(user :string, limit :int) -> {count :int}"
        )

      assert agent.prompt == "Find {{user}} emails with {{limit}}"
      assert agent.signature == "(user :string, limit :int) -> {count :int}"
    end

    test "accepts when no signature is provided (skip validation)" do
      agent = SubAgent.new(prompt: "Find {{user}} emails")
      assert agent.prompt == "Find {{user}} emails"
      assert agent.signature == nil
    end

    test "accepts when no placeholders in prompt" do
      agent =
        SubAgent.new(
          prompt: "Find all emails",
          signature: "(user :string) -> {count :int}"
        )

      assert agent.prompt == "Find all emails"
    end

    test "raises when placeholder not in signature" do
      assert_raise ArgumentError, "placeholders {{user}} not found in signature", fn ->
        SubAgent.new(
          prompt: "Find {{user}} emails",
          signature: "(person :string) -> {count :int}"
        )
      end
    end

    test "raises when multiple placeholders missing" do
      error_message = "placeholders {{user}}, {{sender}} not found in signature"

      assert_raise ArgumentError, error_message, fn ->
        SubAgent.new(
          prompt: "Find {{user}} emails from {{sender}}",
          signature: "(query :string) -> {count :int}"
        )
      end
    end

    test "handles placeholders with whitespace" do
      agent =
        SubAgent.new(
          prompt: "Find {{ user }} emails",
          signature: "(user :string) -> {count :int}"
        )

      assert agent.prompt == "Find {{ user }} emails"
    end

    test "ignores duplicate placeholders" do
      agent =
        SubAgent.new(
          prompt: "Find {{user}} emails for {{user}}",
          signature: "(user :string) -> {count :int}"
        )

      assert agent.prompt == "Find {{user}} emails for {{user}}"
    end

    test "validates nested placeholders like {{data.name}}" do
      # The placeholder extraction treats "data.name" as the placeholder name
      # This should fail because signature has "data", not "data.name"
      assert_raise ArgumentError, "placeholders {{data.name}} not found in signature", fn ->
        SubAgent.new(
          prompt: "Process {{data.name}}",
          signature: "(data :map) -> :string"
        )
      end
    end
  end
end
