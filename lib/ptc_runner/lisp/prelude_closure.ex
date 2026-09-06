defmodule PtcRunner.Lisp.PreludeClosure do
  @moduledoc false

  # Prepare each compiled namespace once. Its entries keep their namespace
  # while resolving sibling helpers; the environment itself never travels in
  # user-visible metadata and is not rebuilt on helper entry.
  @spec tag_internal_environment(map(), term()) :: map()
  def tag_internal_environment(environment, namespace) when is_map(environment) do
    Map.new(environment, fn {name, value} ->
      {name, tag_internal(value, namespace)}
    end)
  end

  # A closure escaping a prelude export keeps the namespace needed to recover
  # its private environment later, while losing the internal-execution marker.
  @spec tag_namespace(term(), term()) :: term()
  def tag_namespace(
        {:closure, params, body, environment, turn_history, %{prelude_internal: true} = metadata},
        namespace
      )
      when is_binary(namespace) do
    metadata =
      metadata
      |> Map.delete(:prelude_internal)
      |> Map.put(:prelude_ns, namespace)

    {:closure, params, body, environment, turn_history, metadata}
  end

  def tag_namespace(value, _namespace), do: value

  defp tag_internal(
         {:closure, params, body, environment, turn_history, metadata},
         namespace
       )
       when is_binary(namespace) do
    metadata =
      metadata
      |> Map.put(:prelude_ns, namespace)
      |> Map.put(:prelude_internal, true)

    {:closure, params, body, environment, turn_history, metadata}
  end

  defp tag_internal(value, _namespace), do: value
end
