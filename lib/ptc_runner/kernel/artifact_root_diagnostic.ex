defmodule PtcRunner.Kernel.ArtifactRootDiagnostic do
  @moduledoc false

  # One owner for the sentences that explain a refused project artifact root.
  #
  # `ptc run` prints them on stderr, because the envelope that would normally
  # carry a diagnostic is the artifact that could not be written; `ptc viewer`
  # prints them as a one-shot failure. Both surfaces must name the same
  # directory and offer the same remedy, so the sentence lives here once and
  # each caller supplies only its own code.
  #
  # The paths are not all operator-typed. The ancestry walk follows symlinks,
  # so a link's target — bytes read from the filesystem — can reach these
  # sentences, and stderr is a terminal. Every path is therefore rendered
  # through `inspect/1`, which escapes control and format characters as well
  # as invalid bytes, and a copyable command is offered only for a path that
  # carries none of them: a remedy a reader cannot safely paste, or that
  # displays differently from what it would run, is worse than no remedy.

  alias PtcRunner.Kernel.ProjectArtifactRoot

  # `Cc` is every control character — C0, DEL, and the C1 block a valid UTF-8
  # path can carry — and `Cf` is every format character, which is where the
  # bidirectional overrides that visually reorder a command live.
  @unsafe_to_paste ~r/[\p{Cc}\p{Cf}]/u

  @doc """
  Renders one `ProjectArtifactRoot` refusal as `{envelope_code, sentence}`.

  The code is the one `ptc run` reports; a caller on another surface may keep
  its own and use the sentence alone.
  """
  @spec describe(ProjectArtifactRoot.ensure_error() | term()) ::
          {:ok, {atom(), binary()}} | :error
  def describe({:project_artifact_root_parent_missing, missing, parent})
      when is_binary(missing) and is_binary(parent) do
    {:ok,
     {:destination_parent_unavailable,
      "#{shown(missing)} does not exist; ptc creates the artifact root and its children but " <>
        "never their parents; " <>
        remedy("mkdir -p", parent, "create #{shown(parent)}") <>
        " or point artifacts.root at an existing directory"}}
  end

  def describe({:project_artifact_root_parent_unsafe_mode, path}) when is_binary(path) do
    {:ok,
     {:destination_parent_unsafe,
      "#{shown(path)} is writable by group or other and is not sticky; a directory above the " <>
        "artifact root must not be replaceable by another user; " <>
        remedy("chmod go-w", path, "remove its group and other write bits")}}
  end

  def describe({:project_artifact_root_parent_foreign_owner, path}) when is_binary(path) do
    {:ok,
     {:destination_parent_unsafe,
      "#{shown(path)} is owned by another user; a directory above the artifact root must be " <>
        "owned by you or by root; point artifacts.root under a directory you own"}}
  end

  def describe({:project_artifact_root_not_owner_only, path}) when is_binary(path) do
    {:ok,
     {:publication_failed,
      "#{shown(path)} is group/other-accessible; artifact directories must be owner-only " <>
        "(0700); " <> remedy("chmod 700", path, "restrict it to its owner")}}
  end

  def describe({:project_artifact_root_incomplete, root}) when is_binary(root) do
    {:ok,
     {:publication_failed,
      "#{shown(root)} is incomplete; remove it and let ptc recreate the owner-only artifact " <>
        "layout"}}
  end

  def describe(_reason), do: :error

  # `inspect/1` quotes the path and escapes anything a terminal would act on,
  # so the reader sees the bytes rather than obeying them.
  defp shown(path), do: inspect(path)

  defp remedy(command, path, fallback) do
    if pasteable?(path), do: "#{command} #{shell_quoted(path)}", else: fallback
  end

  defp pasteable?(path), do: String.valid?(path) and not Regex.match?(@unsafe_to_paste, path)

  # Single quotes suppress every shell expansion; the only byte they cannot
  # carry is the single quote itself, which is closed, escaped, and reopened.
  defp shell_quoted(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
end
