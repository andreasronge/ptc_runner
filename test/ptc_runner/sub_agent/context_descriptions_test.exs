defmodule PtcRunner.SubAgent.ContextDescriptionsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.SystemPrompt

  describe "SubAgent.new/1" do
    test "accepts context_descriptions" do
      agent =
        SubAgent.new(
          prompt: "Test",
          context_descriptions: %{
            products: "List of products",
            user: "Current user"
          }
        )

      assert agent.context_descriptions == %{
               products: "List of products",
               user: "Current user"
             }
    end

    test "raises if context_descriptions is not a map" do
      assert_raise ArgumentError, ~r/context_descriptions must be a map/, fn ->
        SubAgent.new(prompt: "Test", context_descriptions: "not a map")
      end
    end
  end

  describe "SystemPrompt.generate/2 with context_descriptions" do
    test "includes context_descriptions in Data Inventory" do
      agent =
        SubAgent.new(
          prompt: "Test",
          context_descriptions: %{
            products: "List of product maps with {id, name, price, category}",
            question: "The user's question to answer"
          }
        )

      context = %{
        products: [%{id: 1, name: "Laptop", price: 999}],
        question: "What is the cheapest laptop?"
      }

      prompt = SystemPrompt.generate(agent, context: context)

      assert prompt =~ "ctx/products"
      assert prompt =~ "— List of product maps with {id, name, price, category}"
      assert prompt =~ "ctx/question"
      assert prompt =~ "— The user's question to answer"
    end

    test "merges with received_field_descriptions, where received takes precedence" do
      agent =
        SubAgent.new(
          prompt: "Test",
          context_descriptions: %{
            products: "Local description",
            local_only: "Only here"
          }
        )

      context = %{
        products: [],
        local_only: "foo",
        upstream_only: "bar"
      }

      received_field_descriptions = %{
        products: "Upstream description",
        upstream_only: "From upstream"
      }

      prompt =
        SystemPrompt.generate(agent,
          context: context,
          received_field_descriptions: received_field_descriptions
        )

      assert prompt =~ "ctx/products"
      assert prompt =~ "— Upstream description"
      refute prompt =~ "Local description"

      assert prompt =~ "ctx/local_only"
      assert prompt =~ "— Only here"

      assert prompt =~ "ctx/upstream_only"
      assert prompt =~ "— From upstream"
    end

    test "handles string keys in context_descriptions" do
      agent =
        SubAgent.new(
          prompt: "Test",
          context_descriptions: %{"products" => "Description with string key"}
        )

      prompt = SystemPrompt.generate(agent, context: %{"products" => []})
      assert prompt =~ "— Description with string key"
    end

    test "matches atom description to string context key" do
      agent =
        SubAgent.new(
          prompt: "Test",
          context_descriptions: %{products: "Atom key description"}
        )

      prompt = SystemPrompt.generate(agent, context: %{"products" => []})
      assert prompt =~ "— Atom key description"
    end
  end
end
