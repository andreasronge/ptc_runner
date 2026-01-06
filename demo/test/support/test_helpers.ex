defmodule PtcDemo.TestHelpers do
  @moduledoc """
  Shared test helpers for PtcDemo test runners.
  """

  def without_api_keys(fun) do
    old_key = System.get_env("OPENROUTER_API_KEY")

    try do
      System.delete_env("OPENROUTER_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_API_KEY")
      fun.()
    after
      if old_key, do: System.put_env("OPENROUTER_API_KEY", old_key)
    end
  end

  @doc """
  Common mock responses shared by both Lisp and JSON test runners.

  These cover the 13 common test cases + 2 multi-turn test cases.
  """
  def common_mock_responses do
    %{
      # Level 1: Basic Operations
      "How many products are there?" => {:ok, "500 products", nil, 500},
      "How many orders have status 'delivered'?" => {:ok, "200 delivered orders", nil, 200},
      "What is the total revenue from all orders? (sum the total field)" =>
        {:ok, "Total is 2500000", nil, 2_500_000},
      "What is the average product rating?" => {:ok, "Average rating is 3.5", nil, 3.5},
      # Level 2: Intermediate Operations
      "How many employees work remotely?" => {:ok, "100 remote employees", nil, 100},
      "How many products cost more than $500?" => {:ok, "250 products", nil, 250},
      "How many orders over $1000 were paid by credit card?" => {:ok, "150 orders", nil, 150},
      "What is the name of the cheapest product?" => {:ok, "Product 42", nil, "Product 42"},
      # Level 3: Advanced Operations
      "Get the names of the 3 most expensive products" =>
        {:ok, "[Product A, Product B, Product C]", nil, ["Product A", "Product B", "Product C"]},
      "How many orders are either cancelled or refunded?" => {:ok, "300 orders", nil, 300},
      "What is the average salary of senior-level employees? Return only the numeric value." =>
        {:ok, "Average is 150000", nil, 150_000},
      "How many unique products have been ordered? (count distinct product_id values in orders)" =>
        {:ok, "300 unique products", nil, 300},
      "What is the total expense amount for employees in the engineering department? (Find engineering employee IDs, then sum expenses for those employees)" =>
        {:ok, "Total expenses: 50000", nil, 50_000},
      # Multi-turn cases
      "Analyze expense claims to find suspicious patterns. Which employee's spending looks most like potential fraud or abuse? Return their employee_id." =>
        {:ok, "Employee 102 looks suspicious", nil, 102},
      "Use the search tool to find the policy document that covers BOTH 'remote work' AND 'expense reimbursement'. Return the document title." =>
        {:ok, "Policy WFH-2024-REIMB", nil, "Policy WFH-2024-REIMB"}
    }
  end

  @doc """
  Lisp-specific mock responses (in addition to common responses).
  """
  def lisp_specific_mock_responses do
    %{
      "Which expense category has the highest total spending? Return a map with :highest (the top category with its stats) and :breakdown (all categories sorted by total descending). Each category should have :category, :total, :count, and :avg fields." =>
        {:ok, "Travel category", nil,
         %{
           highest: %{category: "travel", total: 25000, count: 50, avg: 500},
           breakdown: [
             %{category: "travel", total: 25000, count: 50, avg: 500},
             %{category: "equipment", total: 15000, count: 30, avg: 500}
           ]
         }},
      "Search for 'security' policies, then fetch the full content for ALL found documents in parallel. Return a list of the full content of these documents." =>
        {:ok, "Found 3 docs", nil, ["Content 1", "Content 2", "Content 3"]}
    }
  end
end
