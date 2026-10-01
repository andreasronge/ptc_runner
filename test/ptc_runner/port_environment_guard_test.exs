defmodule PtcRunner.PortEnvironmentGuardTest do
  use ExUnit.Case, async: true

  test "every executable port under lib explicitly configures its environment" do
    for path <- Path.wildcard("lib/**/*.ex") do
      ast = path |> File.read!() |> Code.string_to_quoted!()

      Macro.prewalk(ast, fn
        {kind, _, [_head, clauses]} = node when kind in [:def, :defp] ->
          assert_explicit_environments(clauses, path)
          node

        node ->
          node
      end)
    end
  end

  defp assert_explicit_environments(body, path) do
    {_, bindings} =
      Macro.prewalk(body, %{}, fn
        {:=, _, [{name, _, context}, value]} = node, bindings
        when is_atom(name) and is_atom(context) ->
          {node, Map.put(bindings, name, value)}

        node, bindings ->
          {node, bindings}
      end)

    Macro.prewalk(body, fn
      {{:., _, [{:__aliases__, _, [:Port]}, :open]}, meta, [{:spawn_executable, _}, options]} =
          node ->
        options = resolve_options(options, bindings)

        assert is_list(options) and Enum.any?(options, &match?({:env, _}, &1)),
               "#{path}:#{meta[:line]} executable port must pass an explicit :env option"

        node

      node ->
        node
    end)
  end

  defp resolve_options({name, _, context}, bindings)
       when is_atom(name) and is_atom(context),
       do: Map.get(bindings, name)

  defp resolve_options(options, _bindings), do: options
end
