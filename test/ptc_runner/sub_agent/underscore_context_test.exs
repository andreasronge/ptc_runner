defmodule PtcRunner.SubAgent.UnderscoreContextTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  @moduledoc """
  Tests that underscore-prefixed fields are ordinary context fields.
  """

  describe "underscore-prefixed context fields" do
    test "renders underscore-prefixed context values in the LLM prompt" do
      articles = [
        %{id: 1, title: "Quantum Basics", keywords: ["quantum"], _body: "Body 1"},
        %{id: 2, title: "Cooking Guide", keywords: ["food"], _body: "Body 2"}
      ]

      agent =
        SubAgent.new(
          prompt: "Find articles about {{topic}}",
          signature:
            "(topic :string, articles [{id :int, title :string, keywords [:string], _body :string}]) -> [{id :int, title :string, keywords [:string], _body :string}]",
          tools: %{"noop" => fn _ -> :ok end},
          max_turns: 2
        )

      llm = fn %{system: system, messages: messages} ->
        user_msg = Enum.find(messages, &(&1.role == :user))
        full_prompt = system <> "\n" <> user_msg.content

        assert full_prompt =~ "Body 1"
        assert full_prompt =~ "Body 2"
        assert full_prompt =~ "_body"

        {:ok,
         ~S"""
         ```clojure
         (return (filter (fn [a] (first (filter #(clojure.string/includes? % "quantum") (:keywords a)))) data/articles))
         ```
         """}
      end

      {:ok, step} =
        SubAgent.run(agent, llm: llm, context: %{topic: "quantum", articles: articles})

      assert [%{"_body" => "Body 1"}] = step.return
    end

    test "tool can access underscore-prefixed context fields via closure" do
      article = %{
        title: "Test Article",
        _body: "This is the body content"
      }

      agent =
        SubAgent.new(
          prompt: "Summarize the article '{{title}}'",
          tools: %{
            "read_content" =>
              {fn _ -> article._body end,
               signature: "() -> :string", description: "Get article content"}
          },
          signature: "(title :string, _body :string) -> {summary :string}",
          max_turns: 2
        )

      llm = fn %{system: system, messages: messages} ->
        user_msg = Enum.find(messages, &(&1.role == :user))
        full_prompt = system <> "\n" <> user_msg.content

        assert full_prompt =~ "This is the body content"
        assert full_prompt =~ "Test Article"

        {:ok,
         ~S"""
         ```clojure
         (let [content (tool/read_content)]
           (return {:summary (str "Summary: " (subs content 0 20))}))
         ```
         """}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: article)

      assert step.return["summary"] =~ "Summary: This is the body"
    end

    test "nested maps in lists render underscore-prefixed values" do
      data = [
        %{id: 1, name: "Alice", _secret: "alice-token"},
        %{id: 2, name: "Bob", _secret: "bob-token"}
      ]

      agent =
        SubAgent.new(
          prompt: "List the names",
          signature: "(users [{id :int, name :string, _secret :string}]) -> [:string]",
          tools: %{"noop" => fn _ -> :ok end},
          max_turns: 2
        )

      llm = fn %{system: system, messages: messages} ->
        user_msg = Enum.find(messages, &(&1.role == :user))
        full_prompt = system <> "\n" <> user_msg.content

        assert full_prompt =~ "alice-token"
        assert full_prompt =~ "bob-token"

        {:ok,
         ~S"""
         ```clojure
         (return (mapv :name data/users))
         ```
         """}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{users: data})

      assert step.return == ["Alice", "Bob"]
    end
  end
end
