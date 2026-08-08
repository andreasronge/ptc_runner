defmodule PtcRunner.Kernel.SchemaPath do
  @moduledoc """
  Schema-explained prefix of an untrusted document path.

  Strict JSON decoding and schema validation report a fault as a raw path into
  the document: object keys as binaries, array indices as non-negative
  integers. Those segments are caller-authored, so a diagnostic must not echo
  them back unchecked.

  `explained_prefix/2` walks such a path through the schema that rejected the
  document and keeps only the leading segments the schema accounts for, tagged
  as `t:PtcRunner.Kernel.CommandPath.segment/0`. Traversal covers `properties`,
  `items`, and `oneOf`, and stops at the first segment the schema cannot
  explain, so every returned segment is one the schema authorizes.

  Keywords that admit caller-chosen names — `additionalProperties` above all —
  are deliberately not traversed, so a path into an open map keeps the segments
  down to that map and drops the caller's own key. A host diagnostic under
  `install` therefore stops at `install` rather than naming the installation.

  A `oneOf` descends into the first branch that explains the current segment.
  A branch selected with knowledge of the whole remaining path could sometimes
  explain more, so the result is the shortest safe prefix rather than the
  longest possible one — truncating early loses diagnostic precision, never
  authority. `PtcRunner.Kernel.CommandPath` authorizes an already-tagged path
  and resolves `oneOf` against the whole remainder instead.
  """

  alias PtcRunner.Kernel.CommandPath

  @doc """
  Returns the leading segments of `path` that `schema` structurally explains.
  """
  @spec explained_prefix([binary() | non_neg_integer()], map()) :: [CommandPath.segment()]
  def explained_prefix(path, schema) when is_list(path), do: walk(path, schema, [])

  defp walk([], _schema, retained), do: Enum.reverse(retained)

  defp walk([segment | rest], schema, retained) do
    case child(schema, segment) do
      {:ok, child} when is_binary(segment) ->
        walk(rest, child, [{:property, segment} | retained])

      {:ok, child} when is_integer(segment) and segment >= 0 ->
        walk(rest, child, [{:index, segment} | retained])

      :error ->
        Enum.reverse(retained)
    end
  end

  defp child(%{"properties" => properties}, segment)
       when is_map(properties) and is_binary(segment),
       do: Map.fetch(properties, segment)

  defp child(%{"items" => items}, segment) when is_integer(segment) and segment >= 0,
    do: {:ok, items}

  defp child(%{"oneOf" => branches}, segment) when is_list(branches) do
    Enum.find_value(branches, :error, fn branch ->
      case child(branch, segment) do
        {:ok, _child} = found -> found
        :error -> false
      end
    end)
  end

  defp child(_schema, _segment), do: :error
end
