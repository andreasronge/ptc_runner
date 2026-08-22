defmodule PtcRunner.Kernel.ManifestRepl do
  @moduledoc """
  Shared manifest-backed REPL acquisition and lifecycle boundary.

  Manifest mode uses the same bounded host catalog, sealed native request,
  inert runtime services, audited-local checks, active-lifecycle marker, and
  active provider acquisition prefix as a one-shot command. Phase-6 trace and
  terminal authority is decided before the opening owner starts. A successful
  opening returns a process-affine `PtcRunner.Kernel.ReplSession` whose owner
  retains one provider session for every evaluation and owns terminal cleanup.

  A private manifest requires `private_terminal: true` and an attached stdin
  and stdout before provider activity, and admits only interactive input. That
  attached-terminal check is an **accident guard, not access control** — the
  same `isatty` limits documented on
  `PtcRunner.Kernel.AnalysisSessionBuilder`. Unlike private analysis profiles,
  there is deliberately no unattended private destination here: a private
  manifest can carry caller-supplied private *input*, not only captured runtime
  telemetry, so the gate stays interactive-only by design rather than offering
  a `--private-unattended` equivalent.
  """

  alias PtcRunner.Kernel.AnalysisTerminal
  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.ManifestReplOpening
  alias PtcRunner.Kernel.ManifestReplPreparation
  alias PtcRunner.Kernel.MissionReplTarget
  alias PtcRunner.Kernel.OwnerFailure
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.TraceLog

  @input_modes [:interactive, :eval, :load, :script, :stdin, :jsonl]
  @option_keys [
    :input_mode,
    :interactive_loop,
    :mission,
    :private_terminal,
    :runtime,
    :terminal_attached,
    :trace_path
  ]

  @type failure :: %{
          required(:code) => atom(),
          required(:provider_activity) => boolean(),
          optional(:declared) => [binary()]
        }

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
           CommandAcquisition.prepare_repl(
             application,
             host_config,
             options.runtime,
             options.interactive_loop
           ) do
      open_prepared(preparation, options)
    else
      {:error, reason} -> {:error, failure(reason, false)}
    end
  end

  def open(_application, _host_config, _opts),
    do: {:error, failure(:invalid_manifest_repl, false)}

  defp open_prepared(preparation, options) do
    result =
      with {:ok, target} <- target(preparation, options.mission),
           {:ok, trace_path} <- authorize_phase_six(preparation, options, target),
           :ok <- maybe_setup_environment(preparation, options.runtime, target),
           {:ok, authority} <- PublicationAuthority.new([]) do
        open_authorized(preparation, authority, trace_path, target)
      end
      |> project_open_result(preparation)

    if match?({:error, _failure}, result), do: ManifestReplPreparation.close(preparation)
    result
  rescue
    _exception ->
      fail_and_close(preparation)
  catch
    _kind, _reason ->
      fail_and_close(preparation)
  end

  defp open_authorized(preparation, authority, trace_path, target) do
    case ManifestReplOpening.start(preparation, authority, trace_path, self(), target) do
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
      interactive_loop = Keyword.get(opts, :interactive_loop, input_mode == :interactive)
      private_terminal = Keyword.get(opts, :private_terminal, false)
      terminal_attached = Keyword.get(opts, :terminal_attached, AnalysisTerminal.attached?())
      trace_path = Keyword.get(opts, :trace_path)
      mission = Keyword.get(opts, :mission)

      if CommandRuntime.valid?(runtime) and input_mode in @input_modes and
           is_boolean(interactive_loop) and
           is_boolean(private_terminal) and is_boolean(terminal_attached) and
           (is_nil(trace_path) or is_binary(trace_path)) and
           (is_nil(mission) or (is_binary(mission) and mission != "")) do
        {:ok,
         %{
           runtime: runtime,
           input_mode: input_mode,
           interactive_loop: interactive_loop,
           private_terminal: private_terminal,
           terminal_attached: terminal_attached,
           trace_path: trace_path,
           mission: mission
         }}
      else
        {:error, :invalid_manifest_repl}
      end
    else
      {:error, :invalid_manifest_repl}
    end
  end

  defp target(_preparation, nil), do: {:ok, :workflow}

  defp target(preparation, mission_name),
    do: MissionReplTarget.new(preparation.prepared_run, preparation.catalog, mission_name)

  defp authorize_phase_six(preparation, options, target) do
    private? = effective_event_policy(preparation, target) == :private

    with :ok <- authorize_terminal(private?, options),
         {:ok, trace_path} <- anchor_trace(options.trace_path),
         :ok <- preflight_trace(trace_path, private?) do
      {:ok, trace_path}
    end
  end

  defp effective_event_policy(preparation, :workflow),
    do: preparation.prepared_run.effective_event_policy

  defp effective_event_policy(_preparation, %MissionReplTarget{} = target),
    do: target.effective_event_policy

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

  defp maybe_setup_environment(%{environment_setup_required: true}, runtime, :workflow),
    do: CommandRuntime.setup_environment(runtime)

  defp maybe_setup_environment(
         %{environment_setup_aliases: aliases},
         runtime,
         %MissionReplTarget{} = target
       ) do
    if Enum.any?(target.aliases, &(&1 in aliases)),
      do: CommandRuntime.setup_environment(runtime),
      else: :ok
  end

  defp maybe_setup_environment(_preparation, _runtime, _target), do: :ok

  defp failure(%CommandDiagnostic{} = diagnostic, _activity),
    do: %{code: diagnostic.code, provider_activity: diagnostic.provider_activity}

  defp failure(reason, activity) when is_atom(reason),
    do: %{code: reason, provider_activity: activity == true}

  defp failure({:unknown_mission, declared}, _activity),
    do: %{code: :unknown_mission, declared: declared, provider_activity: false}

  defp failure(_reason, activity),
    do: %{code: :invalid_manifest_repl, provider_activity: activity == true}

  defp project_open_result({:ok, %ReplSession{}} = result, _preparation), do: result

  defp project_open_result({:error, %OwnerFailure{} = owner_failure}, _preparation) do
    {reason, provider_activity, _stage} =
      OwnerFailure.evidence_or_unknown(owner_failure, :invalid_manifest_repl, :incomplete)

    {:error, failure(reason, provider_activity)}
  end

  defp project_open_result({:error, reason}, preparation),
    do: {:error, failure(reason, activity(preparation))}

  defp fail_and_close(preparation) do
    provider_activity = activity(preparation)
    ManifestReplPreparation.close(preparation)
    {:error, failure(:invalid_manifest_repl, provider_activity)}
  end

  defp activity(preparation) do
    case ProviderActivity.value(preparation.prepared_run.provider_activity) do
      value when is_boolean(value) -> value
      _unknown -> false
    end
  end
end
