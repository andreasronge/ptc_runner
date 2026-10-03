defmodule PtcRunner.ReplSessionRunner do
  @moduledoc false
  alias PtcRunner.Kernel.CommandDiagnosticRenderer
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.InspectOnlyRepl
  alias PtcRunner.Kernel.ManifestRepl
  alias PtcRunner.Kernel.ModelContractDiagnostic
  alias PtcRunner.Kernel.ReplSession

  import PtcRunner.ReplSupport

  def inspect_only(opts, arguments, runner) do
    case InspectOnlyRepl.open(opts[:manifest],
           mission: opts[:mission],
           interactive_loop: interactive_input?(opts, arguments),
           installed_limits: opts[:installed_limits]
         ) do
      {:ok, session} ->
        runner.(session, opts, arguments)

      {:error, %{code: :unknown_mission, declared: declared}} ->
        fail("unknown mission #{inspect(opts[:mission])}; declared: #{Enum.join(declared, ", ")}")

      {:error, %{code: code, diagnostic: diagnostic}} ->
        fail(render_setup_diagnostic(code, diagnostic))

      {:error, %{code: code}} ->
        fail(manifest_repl_error(code))

      {:error, reason} ->
        fail("ptc repl setup failed: #{inspect(reason)}")
    end
  end

  def direct(opts, arguments, runner) do
    constructor =
      if interactive_input?(opts, arguments),
        do: &ReplSession.new_interactive/1,
        else: &ReplSession.new/1

    case constructor.(trace_path: opts[:trace]) do
      {:ok, session} -> runner.(session, opts, arguments)
      {:error, reason} -> fail("ptc repl setup failed: #{inspect(reason)}")
    end
  end

  def manifest(opts, arguments, runner) do
    with {:ok, runtime} <- manifest_runtime(opts),
         {:ok, session} <-
           ManifestRepl.open(opts[:manifest], opts[:host_config],
             runtime: runtime,
             mission: opts[:mission],
             trace_path: opts[:trace],
             private_terminal: Keyword.get(opts, :private_terminal, false),
             terminal_attached: Keyword.fetch!(opts, :terminal_attached),
             input_mode: manifest_input_mode(opts, arguments),
             interactive_loop: interactive_input?(opts, arguments)
           ) do
      runner.(session, opts, arguments)
    else
      {:error, %{code: :unknown_mission, declared: declared}} ->
        fail("unknown mission #{inspect(opts[:mission])}; declared: #{Enum.join(declared, ", ")}")

      {:error, %{code: code, diagnostic: diagnostic}} ->
        rendered = render_setup_diagnostic(code, diagnostic)
        fail(manifest_diagnostic_guidance(rendered, diagnostic))

      {:error, %{code: code}} ->
        fail(manifest_repl_error(code))

      {:error, reason} ->
        fail("ptc repl setup failed: #{inspect(reason)}")
    end
  end

  defp manifest_diagnostic_guidance(
         rendered,
         %{phase: :active_preflight, code: :credential_unavailable}
       ),
       do:
         rendered <>
           "; for credential-free source and helper evaluation, rerun with only " <>
           "--project PROJECT (or --manifest MANIFEST), optional --mission MISSION, " <>
           "--inspect-only, and -e EXPR"

  defp manifest_diagnostic_guidance(rendered, _diagnostic), do: rendered

  defp manifest_input_mode(opts, arguments) do
    cond do
      opts[:load] -> :load
      Keyword.get_values(opts, :eval) != [] -> :eval
      arguments == ["-"] -> :stdin
      arguments != [] -> :script
      true -> :interactive
    end
  end

  defp interactive_input?(opts, arguments),
    do: Keyword.get_values(opts, :eval) == [] and arguments == []

  defp manifest_runtime(opts) do
    case Keyword.fetch(opts, :command_runtime) do
      {:ok, %CommandRuntime{} = runtime} -> {:ok, runtime}
      _missing -> {:error, :invalid_command_runtime}
    end
  end

  defp manifest_repl_error(:host_config_required),
    do: "provider-backed manifest requires --host-config"

  defp manifest_repl_error(:private_terminal_required),
    do: "private manifest REPL requires --private-terminal"

  defp manifest_repl_error(:private_manifest_interactive_only),
    do: "private manifest REPL is interactive-only"

  defp manifest_repl_error(:interactive_terminal_required),
    do: "private manifest REPL requires attached stdin and stdout terminals"

  defp manifest_repl_error(:private_terminal_unsupported),
    do: "--private-terminal requires a private manifest"

  defp manifest_repl_error(:trace_preflight_failed),
    do: "ptc repl trace destination is unavailable"

  defp manifest_repl_error(:environment_file_not_found),
    do: "the named environment file does not exist"

  defp manifest_repl_error(:environment_file_not_regular),
    do: "the named environment file is not a regular file"

  defp manifest_repl_error(:environment_file_unreadable),
    do: "the named environment file cannot be read safely"

  defp manifest_repl_error(:environment_file_too_large),
    do: "the named environment file exceeds the 1 MB limit"

  defp manifest_repl_error(:environment_file_invalid),
    do: "the named environment file contains an invalid assignment"

  defp manifest_repl_error(:environment_file_invalid_utf8),
    do: "the named environment file is not valid UTF-8"

  defp manifest_repl_error(code) when is_atom(code),
    do: "ptc repl setup failed: #{code}"

  defp render_setup_diagnostic(code, diagnostic) do
    case CommandDiagnosticRenderer.render(diagnostic) do
      {:ok, rendered} ->
        warning = ModelContractDiagnostic.warning_line(diagnostic.message)
        if warning != "", do: error(String.trim_trailing(warning, "\n"))
        rendered

      {:error, :invalid_command_diagnostic} ->
        manifest_repl_error(code)
    end
  end
end
