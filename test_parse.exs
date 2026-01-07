# Check the full file
code = File.read!("examples/reprod.clj")

IO.puts("Full file paren balance:")
open = code |> String.graphemes() |> Enum.count(& &1 == "(")
close = code |> String.graphemes() |> Enum.count(& &1 == ")")
IO.puts("Open: #{open}, Close: #{close}, Balance: #{open - close}")

# Check bracket balance
open_b = code |> String.graphemes() |> Enum.count(& &1 == "[")
close_b = code |> String.graphemes() |> Enum.count(& &1 == "]")
IO.puts("Open brackets: #{open_b}, Close brackets: #{close_b}, Balance: #{open_b - close_b}")

# Find where the balance goes wrong
IO.puts("\nTracking balance line by line:")
lines = String.split(code, "\n")
{final_balance, _} = Enum.reduce(Enum.with_index(lines, 1), {0, 0}, fn {line, idx}, {paren_balance, _bracket_balance} ->
  open = line |> String.graphemes() |> Enum.count(& &1 == "(")
  close = line |> String.graphemes() |> Enum.count(& &1 == ")")
  new_balance = paren_balance + open - close

  if open != close do
    IO.puts("Line #{idx}: balance #{paren_balance} -> #{new_balance} | #{String.slice(String.trim(line), 0, 60)}")
  end

  {new_balance, 0}
end)

IO.puts("\nFinal paren balance: #{final_balance}")
