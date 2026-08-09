defmodule PtcRunner.Kernel.ManifestRepl do
  @moduledoc """
  Shared manifest-backed REPL acquisition and lifecycle boundary.

  Manifest mode uses the same bounded host catalog, sealed native request,
  inert runtime services, audited-local checks, provider-activity marker, and
  active provider acquisition prefix as a one-shot command. Phase-6 trace and
  terminal authority is decided before the opening owner starts. A successful
  opening returns a process-affine `PtcRunner.Kernel.ReplSession` whose owner
  retains one provider session for every evaluation and owns terminal cleanup.
  """

  alias PtcRunner.Kernel.AnalysisTerminal
  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.ManifestReplOpening
  alias PtcRunner.Kernel.ManifestReplPreparation
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.TraceLog

  @input_modes [:interactive, :eval, :load, :script, :stdin, :jsonl]
  @option_keys [:input_mode, :private_terminal, :runtime, :terminal_attached, :trace_path]

  @type failure :: %{code: atom(), provider_activity: boolean()}

  @doc """
  Opens one manifest-backed REPL session after phase-6 privacy authorization.

  `:input_mode` is the frontend-classified mode. Mix supplies terminal
  attachment from `AnalysisTerminal`; tests and other trusted frontends may
  pass the already classified boolean explicitly.
  """
  @spec open(binary(), binary() | nil, keyword()) ::
          {:ok, ReplSession.t()} | {:error, failure()}
  def open(application, host_config, opts \\ [])

  def open(application, host_config, opts)
      when is_binary(application) and (is_binary(host_config) or is_nil(host_config)) and
             is_list(opts) do
    with {:ok, options} <- options(opts),
         {:ok, preparation} <-
           CommandAcquisition.prepare_repl(application, host_config, options.runtime) do
      open_prepared(preparation, options)
    else
      {:error, reason} -> {:error, failure(reason, false)}
    end
  end

  def open(_application, _host_config, _opts),
    do: {:error, failure(:invalid_manifest_repl, false)}

  defp open_prepared(preparation, options) do
    result =
      with {:ok, trace_path} <- authorize_phase_six(preparation, options),
           :ok <- maybe_setup_environment(preparation, options.runtime),
           {:ok, authority} <- PublicationAuthority.new([]) do
        open_authorized(preparation, authority, trace_path)
      else
        {:error, reason} ->
          {:error, failure(reason, activity(preparation))}
      end

    if match?({:error, _failure}, result), do: ManifestReplPreparation.close(preparation)
    result
  rescue
    _exception ->
      ManifestReplPreparation.close(preparation)
      {:error, failure(:invalid_manifest_repl, activity(preparation))}
  catch
    _kind, _reason ->
      ManifestReplPreparation.close(preparation)
      {:error, failure(:invalid_manifest_repl, activity(preparation))}
  end

  defp open_authorized(preparation, authority, trace_path) do
    case ManifestReplOpening.start(preparation, authority, trace_path, self()) do
      {:ok, opening} ->
        with {:ok, owner_pid, owner_token} <- ManifestReplOpening.await(opening),
             do: ReplSession.attach(owner_pid, owner_token)

      {:error, reason} ->
        PublicationAuthority.close(authority)
        {:error, reason}
    end
  end

  defp options(opts) do
    keys = Keyword.keys(opts)

    if Keyword.keyword?(opts) and keys -- @option_keys == [] and
         length(keys) == MapSet.size(MapSet.new(keys)) do
      runtime = Keyword.get(opts, :runtime, CommandRuntime.standalone())
      input_mode = Keyword.get(opts, :input_mode, :interactive)
      private_terminal = Keyword.get(opts, :private_terminal, false)
      terminal_attached = Keyword.get(opts, :terminal_attached, AnalysisTerminal.attached?())
      trace_path = Keyword.get(opts, :trace_path)

      if CommandRuntime.valid?(runtime) and input_mode in @input_modes and
           is_boolean(private_terminal) and is_boolean(terminal_attached) and
           (is_nil(trace_path) or is_binary(trace_path)) do
        {:ok,
         %{
           runtime: runtime,
           input_mode: input_mode,
           private_terminal: private_terminal,
           terminal_attached: terminal_attached,
           trace_path: trace_path
         }}
      else
        {:error, :invalid_manifest_repl}
      end
    else
      {:error, :invalid_manifest_repl}
    end
  end

  defp authorize_phase_six(preparation, options) do
    private? = preparation.prepared_run.effective_event_policy == :private

    with :ok <- authorize_terminal(private?, options),
         {:ok, trace_path} <- anchor_trace(options.trace_path),
         :ok <- preflight_trace(trace_path, private?) do
      {:ok, trace_path}
    end
  end

  defp authorize_terminal(true, %{private_terminal: false}),
    do: {:error, :private_terminal_required}

  defp authorize_terminal(true, %{input_mode: input_mode}) when input_mode != :interactive,
    do: {:error, :private_manifest_interactive_only}

  defp authorize_terminal(true, %{terminal_attached: false}),
    do: {:error, :interactive_terminal_required}

  defp authorize_terminal(true, _options), do: :ok

  defp authorize_terminal(false, %{private_terminal: true}),
    do: {:error, :private_terminal_unsupported}

  defp authorize_terminal(false, _options), do: :ok

  defp anchor_trace(nil), do: {:ok, nil}

  defp anchor_trace(path) do
    with {:ok, cwd} <- File.cwd(),
         {:ok, anchored} <- PrivateDirectory.anchor(path, cwd) do
      {:ok, anchored}
    else
      _failure -> {:error, :trace_preflight_failed}
    end
  end

  defp preflight_trace(nil, _private?), do: :ok

  defp preflight_trace(path, private?) do
    case TraceLog.preflight_destination(path, private?) do
      :ok -> :ok
      {:error, _reason} -> {:error, :trace_preflight_failed}
    end
  end

  defp maybe_setup_environment(%{environment_setup_required: true}, runtime),
    do: CommandRuntime.setup_environment(runtime)

  defp maybe_setup_environment(_preparation, _runtime), do: :ok

  defp failure(%CommandDiagnostic{} = diagnostic, _activity),
    do: %{code: diagnostic.code, provider_activity: diagnostic.provider_activity}

  defp failure(reason, activity) when is_atom(reason),
    do: %{code: reason, provider_activity: activity == true}

  defp activity(preparation) do
    case ProviderActivity.value(preparation.prepared_run.provider_activity) do
      value when is_boolean(value) -> value
      _unknown -> false
    end
  end
end
