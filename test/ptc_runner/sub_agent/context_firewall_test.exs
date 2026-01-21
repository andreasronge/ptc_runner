defmodule PtcRunner.SubAgent.ContextFirewallTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  @moduledoc """
  Tests for context firewall - fields prefixed with `_` are hidden from LLM prompts
  but remain accessible to tools and flow through return values.
  """

  describe "context firewall with _prefixed fields" do
    test "hides _body values from LLM prompt but includes them in return value" do
      articles = [
        %{id: 1, title: "Quantum Basics", keywords: ["quantum"], _body: "Secret body 1"},
        %{id: 2, title: "Cooking Guide", keywords: ["food"], _body: "Secret body 2"},
        %{id: 3, title: "Quantum Physics", keywords: ["quantum"], _body: "Secret body 3"}
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

        # Verify _body VALUES are NOT in the prompt
        refute full_prompt =~ "Secret body 1"
        refute full_prompt =~ "Secret body 2"
        refute full_prompt =~ "Secret body 3"

        # Verify visible field values ARE in the prompt
        assert full_prompt =~ "quantum"

        {:ok,
         ~S"""
         ```clojure
         (return (filter (fn [a] (first (filter #(clojure.string/includes? % "quantum") (:keywords a)))) data/articles))
         ```
         """}
      end

      {:ok, step} =
        SubAgent.run(agent, llm: llm, context: %{topic: "quantum", articles: articles})

      # Verify the return value DOES include _body fields
      assert length(step.return) == 2
      assert Enum.all?(step.return, fn article -> Map.has_key?(article, "_body") end)

      # Verify the actual _body values are preserved
      bodies = Enum.map(step.return, & &1["_body"])
      assert "Secret body 1" in bodies
      assert "Secret body 3" in bodies
    end

    test "tool can access _prefixed context fields via closure" do
      article = %{
        title: "Test Article",
        _body: "This is the secret body content"
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

        # Verify _body VALUE is NOT shown in the prompt
        refute full_prompt =~ "This is the secret body content"

        # Verify title IS shown
        assert full_prompt =~ "Test Article"

        # Use tool/ namespace (not ctx/)
        {:ok,
         ~S"""
         ```clojure
         (let [content (tool/read_content)]
           (return {:summary (str "Summary: " (subs content 0 20))}))
         ```
         """}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: article)

      # Verify the summary was created using content from tool
      assert step.return["summary"] =~ "Summary: This is the secret"
    end

    test "nested maps in lists have _prefixed values filtered silently" do
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

        # Verify _secret VALUES are NOT in the prompt
        refute full_prompt =~ "alice-token"
        refute full_prompt =~ "bob-token"

        # Note: _secret key name may appear in signature type annotation, that's OK
        # The important thing is VALUES are hidden

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
