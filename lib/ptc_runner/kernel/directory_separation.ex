defmodule PtcRunner.Kernel.DirectorySeparation do
  @moduledoc false

  alias PtcRunner.Kernel.AnalysisDirectory

  @typedoc """
  What a caller supplied a directory for.

  `id` is the stable machine identifier reported to automation; `label` is the
  option or resource spelling shown to an operator. Neither carries a path.
  """
  @type role :: %{required(:id) => binary(), required(:label) => binary()}

  @type conflict :: %{
          required(:left_role) => binary(),
          required(:right_role) => binary(),
          required(:relation) => binary(),
          required(:message) => binary()
        }

  @doc """
  Verifies that every supplied directory is physically separate from the rest.

  On rejection the first conflicting pair is reported with both roles and
  their physical relationship. Diagnostics never disclose supplied paths,
  resolved paths, symlink targets, or directory identities: a caller learns
  which two roles collide and how, and nothing about the filesystem beyond it.
  """
  @spec verify([{role(), AnalysisDirectory.resolved()}]) :: :ok | {:error, conflict()}
  def verify(directories) when is_list(directories) do
    case AnalysisDirectory.first_conflict(directories) do
      nil ->
        :ok

      {left, right, relationship} ->
        {:error,
         %{
           left_role: left.id,
           right_role: right.id,
           relation: Atom.to_string(relationship),
           message: message(left.label, right.label, relationship)
         }}
    end
  end

  defp message(left, right, :same),
    do: separation_required(left, right) <> "; they resolve to the same physical directory"

  defp message(left, right, :left_contains_right),
    do: separation_required(left, right) <> "; #{left} contains #{right}"

  defp message(left, right, :right_contains_left),
    do: separation_required(left, right) <> "; #{right} contains #{left}"

  defp separation_required(left, right),
    do: "directories for #{left} and #{right} must be physically separate"
end
