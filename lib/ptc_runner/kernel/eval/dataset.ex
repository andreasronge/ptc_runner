defmodule PtcRunner.Kernel.Eval.Dataset do
  @moduledoc false

  @spec build(integer()) :: map()
  def build(seed) when is_integer(seed) do
    %{
      "products" => products(seed),
      "orders" => orders(seed),
      "employees" => employees(seed),
      "expenses" => expenses(seed)
    }
  end

  defp products(seed) do
    for id <- 1..500 do
      %{
        "id" => id,
        "name" => "Product #{id}",
        "price" => 50 + Integer.mod(id * 37 + seed, 95_000) / 100
      }
    end
  end

  defp orders(seed) do
    statuses = ["pending", "shipped", "delivered", "cancelled", "refunded"]
    payments = ["credit_card", "paypal", "bank_transfer", "crypto"]

    for id <- 1..1_000 do
      %{
        "id" => id,
        "product_id" => Integer.mod(id * 17 + seed, 500) + 1,
        "total" => 10 + Integer.mod(id * 101 + seed, 499_000) / 100,
        "status" => Enum.at(statuses, Integer.mod(id + seed, length(statuses))),
        "payment_method" => Enum.at(payments, Integer.mod(id * 3 + seed, length(payments)))
      }
    end
  end

  defp employees(seed) do
    departments = ["engineering", "sales", "marketing", "support", "hr", "finance"]

    for id <- 1..200 do
      %{
        "id" => id,
        "department" => Enum.at(departments, Integer.mod(id + seed, length(departments))),
        "remote" => Integer.mod(id * 5 + seed, 3) == 0
      }
    end
  end

  defp expenses(seed) do
    for id <- 1..800 do
      %{
        "id" => id,
        "employee_id" => Integer.mod(id * 11 + seed, 200) + 1,
        "amount" => 5 + Integer.mod(id * 43 + seed, 199_500) / 100
      }
    end
  end
end
