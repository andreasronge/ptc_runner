defmodule PtcDemo.SampleData do
  @moduledoc """
  Sample data generator for demonstrating PtcRunner's context efficiency.

  Generates realistic datasets that would be expensive to pass through
  LLM context in traditional function calling, but are efficiently
  processed by PtcRunner in BEAM memory.
  """

  @doc """
  Generates a list of products (500 items).
  In traditional function calling, this would consume ~50KB of context.
  """
  def products do
    categories = ["electronics", "clothing", "food", "books", "sports", "home", "toys"]
    statuses = ["active", "discontinued", "out_of_stock"]

    for i <- 1..500 do
      %{
        "id" => i,
        "name" => "Product #{i}",
        "category" => Enum.random(categories),
        "price" => :rand.uniform(1000) + :rand.uniform(100) / 100,
        "stock" => :rand.uniform(500),
        "rating" => Float.round(:rand.uniform() * 4 + 1, 1),
        "status" => Enum.random(statuses),
        "created_at" => random_date(2023, 2024)
      }
    end
  end

  @doc """
  Generates a list of orders (1000 items).
  In traditional function calling, this would consume ~100KB of context.
  """
  def orders do
    statuses = ["pending", "shipped", "delivered", "cancelled", "refunded"]
    payment_methods = ["credit_card", "paypal", "bank_transfer", "crypto"]

    for i <- 1..1000 do
      %{
        "id" => i,
        "customer_id" => :rand.uniform(200),
        "product_id" => :rand.uniform(500),
        "quantity" => :rand.uniform(10),
        "total" => :rand.uniform(5000) + :rand.uniform(100) / 100,
        "status" => Enum.random(statuses),
        "payment_method" => Enum.random(payment_methods),
        "created_at" => random_date(2024, 2024)
      }
    end
  end

  @doc """
  Generates a list of employees (200 items).
  """
  def employees do
    departments = ["engineering", "sales", "marketing", "support", "hr", "finance"]
    levels = ["junior", "mid", "senior", "lead", "manager", "director"]

    for i <- 1..200 do
      base_salary = 50_000 + :rand.uniform(150_000)

      %{
        "id" => i,
        "name" => "Employee #{i}",
        "department" => Enum.random(departments),
        "level" => Enum.random(levels),
        "salary" => base_salary,
        "bonus" => Float.round(base_salary * :rand.uniform() * 0.2, 2),
        "years_employed" => :rand.uniform(15),
        "remote" => :rand.uniform(2) == 1
      }
    end
  end

  @doc """
  Generates expense records (800 items).
  """
  def expenses do
    categories = ["travel", "equipment", "software", "meals", "office", "training"]
    statuses = ["pending", "approved", "rejected", "reimbursed"]

    for i <- 1..800 do
      %{
        "id" => i,
        "employee_id" => :rand.uniform(200),
        "category" => Enum.random(categories),
        "amount" => :rand.uniform(2000) + :rand.uniform(100) / 100,
        "description" => "Expense #{i} description",
        "status" => Enum.random(statuses),
        "date" => random_date(2024, 2024)
      }
    end
  end

  @doc """
  Returns available datasets and their sizes.
  """
  def available_datasets do
    %{
      "products" => "500 product records (~50KB)",
      "orders" => "1000 order records (~100KB)",
      "employees" => "200 employee records (~20KB)",
      "expenses" => "800 expense records (~80KB)"
    }
  end

  @doc """
  Returns schema metadata for each dataset.
  This simulates what MCP tools provide via their output schemas.
  """
  def schemas do
    %{
      "products" => %{
        description: "Product catalog",
        fields: %{
          "id" => "integer",
          "name" => "string",
          "category" => "enum(electronics, clothing, food, books, sports, home, toys)",
          "price" => "number (1-1100)",
          "stock" => "integer (0-500)",
          "rating" => "number (1.0-5.0)",
          "status" => "enum(active, discontinued, out_of_stock)",
          "created_at" => "date (YYYY-MM-DD)"
        }
      },
      "orders" => %{
        description: "Customer orders",
        fields: %{
          "id" => "integer",
          "customer_id" => "integer (1-200)",
          "product_id" => "integer (1-500)",
          "quantity" => "integer (1-10)",
          "total" => "number (1-5100)",
          "status" => "enum(pending, shipped, delivered, cancelled, refunded)",
          "payment_method" => "enum(credit_card, paypal, bank_transfer, crypto)",
          "created_at" => "date (YYYY-MM-DD)"
        }
      },
      "employees" => %{
        description: "Employee directory",
        fields: %{
          "id" => "integer",
          "name" => "string",
          "department" => "enum(engineering, sales, marketing, support, hr, finance)",
          "level" => "enum(junior, mid, senior, lead, manager, director)",
          "salary" => "integer (50000-200000)",
          "bonus" => "number",
          "years_employed" => "integer (1-15)",
          "remote" => "boolean"
        }
      },
      "expenses" => %{
        description: "Expense reports",
        fields: %{
          "id" => "integer",
          "employee_id" => "integer (1-200)",
          "category" => "enum(travel, equipment, software, meals, office, training)",
          "amount" => "number (1-2100)",
          "description" => "string",
          "status" => "enum(pending, approved, rejected, reimbursed)",
          "date" => "date (YYYY-MM-DD)"
        }
      }
    }
  end

  @doc """
  Formats schemas for LLM consumption (like MCP tool descriptions).
  """
  def schema_prompt do
    schemas()
    |> Enum.map(fn {name, schema} ->
      fields =
        schema.fields
        |> Enum.map(fn {field, type} -> "    #{field}: #{type}" end)
        |> Enum.join("\n")

      "#{name} - #{schema.description}:\n#{fields}"
    end)
    |> Enum.join("\n\n")
  end

  @doc """
  Loads a dataset by name.
  """
  def load(name) do
    case name do
      "products" -> {:ok, products()}
      "orders" -> {:ok, orders()}
      "employees" -> {:ok, employees()}
      "expenses" -> {:ok, expenses()}
      _ -> {:error, "Unknown dataset: #{name}"}
    end
  end

  defp random_date(start_year, end_year) do
    year = Enum.random(start_year..end_year)
    month = :rand.uniform(12)
    day = :rand.uniform(28)
    "#{year}-#{String.pad_leading("#{month}", 2, "0")}-#{String.pad_leading("#{day}", 2, "0")}"
  end
end
