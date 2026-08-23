defmodule PtcRunner.Kernel.CommandDiagnosticRenderer do
  @moduledoc false

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRunRef

  @pointer_pattern ~r/\A\/[A-Za-z0-9._~\/-]+\z/
  @source_name_pattern ~r/\A[A-Za-z0-9._~-][A-Za-z0-9._~\/-]*\z/

  @spec render(CommandDiagnostic.t()) :: {:ok, binary()} | {:error, :invalid_command_diagnostic}
  def render(%CommandDiagnostic{} = diagnostic) do
    if CommandDiagnostic.valid?(diagnostic),
      do: {:ok, render_map(CommandDiagnostic.to_map(diagnostic), nil)},
      else: {:error, :invalid_command_diagnostic}
  end

  def render(_diagnostic), do: {:error, :invalid_command_diagnostic}

  @doc false
  @spec render_with_run_ref(CommandDiagnostic.t() | CommandOutcome.t(), binary()) ::
          {:ok, binary()} | {:error, :invalid_command_diagnostic}
  def render_with_run_ref(%CommandDiagnostic{} = diagnostic, run_ref) do
    if CommandDiagnostic.valid?(diagnostic) and CommandRunRef.valid?(run_ref),
      do: {:ok, render_map(CommandDiagnostic.to_map(diagnostic), run_ref)},
      else: {:error, :invalid_command_diagnostic}
  end

  def render_with_run_ref(%CommandOutcome{} = outcome, run_ref) do
    with true <- CommandOutcome.valid?(outcome),
         true <- CommandRunRef.valid?(run_ref),
         %{"error" => error} <- CommandOutcome.to_map(outcome) do
      {:ok, render_map(error, run_ref)}
    else
      _invalid -> {:error, :invalid_command_diagnostic}
    end
  end

  def render_with_run_ref(_diagnostic, _run_ref),
    do: {:error, :invalid_command_diagnostic}

  defp render_map(error, run_ref) do
    base =
      "#{error["phase"]}/#{error["code"]}: " <>
        subject_prefix(error["subject"]) <>
        error["message"] <>
        location_suffix(error)

    run_ref_suffix = if run_ref, do: " (run_ref: #{run_ref})", else: ""
    base <> run_ref_suffix <> diagnostic_suffix(error)
  end

  defp diagnostic_suffix(%{
         "phase" => "active_preflight",
         "code" => "credential_unavailable",
         "subject" => %{"operation" => "credentials"}
       }),
       do: "; export it, pass --env-file PATH, or use a host file credential"

  defp diagnostic_suffix(_error), do: ""

  defp location_suffix(%{
         "phase" => "project",
         "code" => "project_schema_invalid",
         "source" => %{"kind" => "project"},
         "path" => path
       })
       when is_binary(path) and path != "",
       do: " at " <> path

  defp location_suffix(%{
         "phase" => "project",
         "code" => "project_schema_invalid",
         "source" => %{"kind" => "project"},
         "path" => ""
       }),
       do: " at document root"

  defp location_suffix(%{
         "phase" => "application",
         "code" => code,
         "source" => %{"kind" => "application"},
         "path" => path
       })
       when code in ["schema_violation", "required_property_missing"] and is_binary(path) and
              path != "",
       do: " at " <> path

  defp location_suffix(%{
         "phase" => "application",
         "code" => code,
         "source" => %{"kind" => "application"},
         "path" => ""
       })
       when code in ["schema_violation", "required_property_missing"],
       do: " at document root"

  defp location_suffix(%{
         "phase" => "host",
         "code" => "host_schema_invalid",
         "source" => %{"kind" => "host"},
         "path" => path
       })
       when is_binary(path) and path != "",
       do: " at " <> path

  defp location_suffix(%{
         "phase" => "host",
         "code" => "host_schema_invalid",
         "source" => %{"kind" => "host"},
         "path" => ""
       }),
       do: " at document root"

  defp location_suffix(%{
         "phase" => "bundle",
         "source" => %{"kind" => "component", "name" => name},
         "span" => %{"start_byte" => start_byte, "end_byte" => end_byte}
       })
       when is_binary(name) and is_integer(start_byte) and is_integer(end_byte),
       do: " at #{name} bytes [#{start_byte},#{end_byte})"

  defp location_suffix(%{
         "phase" => "application",
         "code" => "input_contract_failed",
         "source" => %{"kind" => kind},
         "path" => path
       })
       when kind in ["application", "external_input", "input_contract"] and
              is_binary(path) and path != "",
       do: " at " <> terminal_contract_path(path)

  defp location_suffix(%{
         "phase" => "result_cleanup",
         "code" => "result_contract_failed",
         "source" => %{"kind" => "result_contract"},
         "path" => path
       })
       when is_binary(path) and path != "",
       do: " at " <> terminal_contract_path(path)

  defp location_suffix(%{
         "phase" => "application",
         "code" => "contract_invalid",
         "source" => %{"kind" => kind, "name" => name},
         "path" => path
       })
       when kind in ["input_contract", "result_contract"] and is_binary(name) and
              is_binary(path) and path != "",
       do: " at #{terminal_contract_path(path)} in #{terminal_source_name(name)}"

  defp location_suffix(%{
         "phase" => "application",
         "code" => "override_invalid",
         "source" => %{"kind" => "component_override"},
         "path" => path
       })
       when is_binary(path) and path != "",
       do: " at " <> path

  defp location_suffix(_error), do: ""

  defp terminal_contract_path(path), do: terminal_literal(path, @pointer_pattern)

  defp terminal_source_name(name), do: terminal_literal(name, @source_name_pattern)

  defp terminal_literal(text, pattern) do
    case text =~ pattern do
      true -> text
      false -> inspect(text, binaries: :as_strings, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp subject_prefix(%{
         "kind" => "provider",
         "name" => name,
         "operation" => operation,
         "occurrence" => nil
       }),
       do: "provider/#{name}/#{operation}: "

  defp subject_prefix(%{
         "kind" => "provider",
         "name" => name,
         "operation" => operation,
         "occurrence" => %{"destination" => destination, "index" => index}
       }),
       do: "provider/#{name}/#{operation} at #{destination}[#{index}]: "

  defp subject_prefix(nil), do: ""
end
