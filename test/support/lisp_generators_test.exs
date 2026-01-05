defmodule PtcRunner.TestSupport.LispGeneratorsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PtcRunner.Lisp.{Formatter, Parser}
  alias PtcRunner.Step
  alias PtcRunner.TestSupport.LispGenerators, as: Gen

  describe "roundtrip parsing" do
    property "formatted expressions parse successfully" do
      check all(ast <- Gen.gen_expr(2)) do
        source = Formatter.format(ast)
        assert is_binary(source)

        case Parser.parse(source) do
          {:ok, parsed} ->
            assert ast_equivalent?(ast, parsed),
                   "Roundtrip failed:\nOriginal: #{inspect(ast)}\nSource: #{source}\nParsed: #{inspect(parsed)}"

          {:error, reason} ->
            flunk("Parse failed for source: #{source}\nReason: #{inspect(reason)}")
        end
      end
    end

    property "string escape sequences roundtrip correctly" do
      check all(str_ast <- Gen.gen_string_with_escapes()) do
        source = Formatter.format(str_ast)

        case Parser.parse(source) do
          {:ok, parsed} ->
            assert ast_equivalent?(str_ast, parsed),
                   "String roundtrip failed:\nOriginal: #{inspect(str_ast)}\nSource: #{source}\nParsed: #{inspect(parsed)}"

          {:error, reason} ->
            flunk("Parse failed for escaped string: #{source}\nReason: #{inspect(reason)}")
        end
      end
    end
  end

  describe "evaluation safety" do
    @tag :capture_log
    property "valid programs evaluate without crashes" do
      check all(ast <- Gen.gen_expr(2)) do
        source = Formatter.format(ast)
        ctx = %{items: [1, 2, 3], user: %{name: "test", active: true}}

        tools = build_tools_for_source(source)
        result = safe_run(source, context: ctx, tools: tools)

        # Should return {:ok, %Step{}} or {:error, %Step{}}, never crash the interpreter
        assert match?({:ok, %Step{}}, result) or match?({:error, %Step{}}, result),
               "Unexpected result for source: #{source}\nResult: #{inspect(result)}"
      end
    end
  end

  # Helpers

  defp ast_equivalent?(a, b) when is_float(a) and is_float(b) do
    abs(a - b) < 1.0e-9
  end

  defp ast_equivalent?({tag, children1}, {tag, children2})
       when is_list(children1) and is_list(children2) do
    length(children1) == length(children2) and
      Enum.zip(children1, children2) |> Enum.all?(fn {c1, c2} -> ast_equivalent?(c1, c2) end)
  end

  defp ast_equivalent?({tag, v1}, {tag, v2}) do
    ast_equivalent?(v1, v2)
  end

  defp ast_equivalent?(a, b) do
    a == b
  end

  defp build_tools_for_source(source) do
    base_tools = %{"test_tool" => fn _args -> :result end}

    # Match ctx/tool-name patterns in generated source
    Regex.scan(~r/\(ctx\/([a-z0-9_-]+)/, source)
    |> Enum.reduce(base_tools, fn [_full, tool_name], acc ->
      Map.put_new(acc, tool_name, fn _args -> :result end)
    end)
  end

  defp safe_run(source, opts) do
    PtcRunner.Lisp.run(source, opts)
  rescue
    _e -> {:error, :runtime_error}
  end
end
