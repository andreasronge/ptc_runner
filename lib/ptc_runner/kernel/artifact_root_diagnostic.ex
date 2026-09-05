defmodule PtcRunner.Kernel.ArtifactRootDiagnostic do
  @moduledoc false

  # One owner for the sentences that explain a refused project artifact root.
  #
  # `ptc run` prints them on stderr, because the envelope that would normally
  # carry a diagnostic is the artifact that could not be written; `ptc viewer`
  # prints them as a one-shot failure. Both surfaces must name the same
  # directory and offer the same remedy, so the sentence lives here once and
  # each caller supplies only its own code.

  alias PtcRunner.Kernel.ProjectArtifactRoot

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
      "#{missing} does not exist; ptc creates the artifact root and its children but never " <>
        "their parents; mkdir -p #{parent} or point artifacts.root at an existing directory"}}
  end

  def describe({:project_artifact_root_parent_unsafe_mode, path}) when is_binary(path) do
    {:ok,
     {:destination_parent_unsafe,
      "#{path} is writable by group or other and is not sticky; a directory above the artifact " <>
        "root must not be replaceable by another user; chmod go-w #{path}"}}
  end

  def describe({:project_artifact_root_parent_foreign_owner, path}) when is_binary(path) do
    {:ok,
     {:destination_parent_unsafe,
      "#{path} is owned by another user; a directory above the artifact root must be owned by " <>
        "you or by root; point artifacts.root under a directory you own"}}
  end

  def describe({:project_artifact_root_not_owner_only, path}) when is_binary(path) do
    {:ok,
     {:publication_failed,
      "#{path} is group/other-accessible; artifact directories must be owner-only (0700); " <>
        "chmod 700 #{path}"}}
  end

  def describe({:project_artifact_root_incomplete, root}) when is_binary(root) do
    {:ok,
     {:publication_failed,
      "#{root} is incomplete; remove it and let ptc recreate the owner-only artifact layout"}}
  end

  def describe(_reason), do: :error
end
