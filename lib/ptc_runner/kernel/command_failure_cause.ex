defmodule PtcRunner.Kernel.CommandFailureCause do
  @moduledoc """
  Closed public causes for command failures before canonical evidence exists.

  The cause names a failure class, never a path, exception class, message, or
  raw operating-system reason. Unknown inputs become `unexpected_exception`.
  """

  @rows [
    lock_timeout: "A reservation or admission lock expired.",
    filesystem_error: "A filesystem operation failed.",
    permission: "The operating system denied access.",
    unexpected_exception: "A bounded operation raised or returned an unknown failure.",
    subprocess_failed: "A subprocess failed before execution evidence began.",
    invalid_configuration: "A configuration value could not be used.",
    resource_unavailable: "A required local resource was unavailable.",
    destination_exists: "An output destination was already occupied."
  ]
  @causes Keyword.keys(@rows)

  @permission_reasons [:eacces, :eperm, :erofs]
  @filesystem_reasons [:eio, :edquot, :enospc, :enoent, :enotdir, :eisdir]

  @spec values() :: [atom()]
  def values, do: @causes

  @spec valid?(term()) :: boolean()
  def valid?(cause), do: cause in @causes

  @spec from_reason(term()) :: atom()
  def from_reason({:reason, reason}), do: from_reason(reason)
  def from_reason({:exception, _class}), do: :unexpected_exception
  def from_reason({:destination_unavailable, reason}), do: from_reason(reason)
  def from_reason(reason) when reason in @permission_reasons, do: :permission
  def from_reason(reason) when reason in @filesystem_reasons, do: :filesystem_error
  def from_reason(:lock_timeout), do: :lock_timeout
  def from_reason(:destination_exists), do: :destination_exists
  def from_reason(:destination_collision), do: :destination_exists
  def from_reason(:subprocess_failed), do: :subprocess_failed
  def from_reason(:invalid_destination), do: :invalid_configuration
  def from_reason(:project_artifact_root_invalid), do: :invalid_configuration
  def from_reason({:project_artifact_root_incomplete, _path}), do: :invalid_configuration
  def from_reason({:project_artifact_root_not_owner_only, _path}), do: :permission
  def from_reason({:project_artifact_root_parent_missing, _path, _parent}), do: :filesystem_error
  def from_reason({:project_artifact_root_parent_unsafe_mode, _path}), do: :permission
  def from_reason({:project_artifact_root_parent_foreign_owner, _path}), do: :permission
  def from_reason({:project_artifact_root_parent_unwritable, _path}), do: :permission

  def from_reason({:project_artifact_root_parent_creation_refused, _path}),
    do: :resource_unavailable

  def from_reason(:private_destination_required), do: :invalid_configuration
  def from_reason(:private_directory_unsupported), do: :invalid_configuration
  def from_reason(:invalid_trace_path), do: :invalid_configuration
  def from_reason(:invalid_inspection_path), do: :invalid_configuration
  def from_reason(:destination_directory_missing), do: :filesystem_error
  def from_reason(:trace_directory_missing), do: :filesystem_error
  def from_reason(:inspection_directory_missing), do: :filesystem_error
  def from_reason(:result_directory_missing), do: :filesystem_error
  def from_reason(:inspection_persistence_failed), do: :filesystem_error
  def from_reason(:private_directory_parent_unsafe), do: :permission
  def from_reason(:trace_destination_unsafe), do: :permission
  def from_reason(:inspection_destination_unsafe), do: :permission
  def from_reason(:result_destination_unsafe), do: :permission
  def from_reason(:source_unavailable), do: :resource_unavailable
  def from_reason(:private_directory_unavailable), do: :resource_unavailable
  def from_reason(:private_directory_parent_unavailable), do: :resource_unavailable
  def from_reason(:recovery_reservation_failed), do: :resource_unavailable
  def from_reason(:trace_destination_unavailable), do: :resource_unavailable
  def from_reason(:inspection_destination_unavailable), do: :resource_unavailable
  def from_reason(:result_destination_unavailable), do: :resource_unavailable
  def from_reason(:environment_file_not_found), do: :filesystem_error
  def from_reason(:environment_file_not_regular), do: :invalid_configuration
  def from_reason(:environment_file_unreadable), do: :permission
  def from_reason(:environment_file_too_large), do: :resource_unavailable
  def from_reason(:environment_file_invalid_utf8), do: :invalid_configuration
  def from_reason(:destination_unavailable), do: :resource_unavailable
  def from_reason(_reason), do: :unexpected_exception

  @spec rows() :: [{atom(), String.t()}]
  def rows, do: @rows
end
