defmodule PtcRunner.TestSupport.PublicStepAssertions do
  @moduledoc false

  import ExUnit.Assertions

  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.RuntimeCallable
  alias PtcRunner.Step
  alias PtcRunner.Turn

  @doc """
  Fails if a public step exposes internal PTC-Lisp runtime values.
  """
  def assert_public_step!(%Step{} = step) do
    step
    |> Map.take([
      :return,
      :fail,
      :memory,
      :journal,
      :turns,
      :child_steps,
      :tool_calls,
      :pmap_calls,
      :catalog_ops,
      :tool_cache
    ])
    |> assert_public_value!("step")
  end

  def assert_public_value!(value, path \\ "value") do
    case internal_value_reason(value) do
      nil ->
        walk_public_value!(value, path)

      reason ->
        flunk("public payload exposed #{reason} at #{path}: #{inspect(value)}")
    end
  end

  defp walk_public_value!(%Step{} = step, path), do: assert_public_step!(step, path)

  defp walk_public_value!(%Turn{} = turn, path) do
    turn
    |> Map.take([:result, :prints, :tool_calls, :memory])
    |> assert_public_value!(path)
  end

  defp walk_public_value!(value, _path) when is_struct(value), do: :ok

  defp walk_public_value!(%{} = map, path) do
    Enum.each(map, fn {key, value} ->
      assert_public_value!(key, "#{path}.{key}")
      assert_public_value!(value, "#{path}[#{inspect(key)}]")
    end)
  end

  defp walk_public_value!(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.each(fn {value, index} -> assert_public_value!(value, "#{path}[#{index}]") end)
  end

  defp walk_public_value!(tuple, path) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.each(fn {value, index} -> assert_public_value!(value, "#{path}.{#{index}}") end)
  end

  defp walk_public_value!(_value, _path), do: :ok

  defp assert_public_step!(%Step{} = step, path) do
    step
    |> Map.take([
      :return,
      :fail,
      :memory,
      :journal,
      :turns,
      :child_steps,
      :tool_calls,
      :pmap_calls,
      :catalog_ops,
      :tool_cache
    ])
    |> assert_public_value!(path)
  end

  defp internal_value_reason(%LispKeyword{}), do: "Lisp keyword"
  defp internal_value_reason(%RuntimeCallable{}), do: "runtime callable"

  defp internal_value_reason({:closure, _params, _body, _env, _turn_history, _metadata}),
    do: "closure"

  defp internal_value_reason({:__ptc_return__, _value}), do: "return sentinel"
  defp internal_value_reason({:__ptc_fail__, _value}), do: "fail sentinel"
  defp internal_value_reason(_value), do: nil
end
