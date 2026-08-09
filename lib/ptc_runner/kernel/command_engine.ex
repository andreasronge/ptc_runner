defmodule PtcRunner.Kernel.CommandEngine do
  @moduledoc """
  Shared command parser and dispatch router.

  The engine owns the single argv grammar and returns only sealed terminal
  outcomes. Cohesive acquisition, doctor, destination, and run-dispatch
  components own their respective phase ranges. Shared code never writes
  process streams, halts the VM, or renders arbitrary failures.

  Frontend-owned switches such as `--envelope` are accepted only through a
  `CommandEntry`; the direct `prepare/1` and `dispatch/1` APIs reject them.

  Provider-free and provider-backed `run` commands complete through the same
  owner-backed execution and publication path. Provider-free runs retain
  `ExecutionSessionOwner` while omitting only the provider session.
  `doctor --connect` remains its own active operation. `models` projects only
  public installation declarations and invokes no provider runtime service.
  `init` validates its fixed memory scaffold before atomically publishing a
  complete directory without replacing an existing target.
  """

  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDestination
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandDoctor
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandInitializer
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandParser
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRejection
  alias PtcRunner.Kernel.CommandRunDispatch
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PublicationAuthority

  @fallback_run_ref "cmd-00000000000000000000000000"

  @type prepared :: CommandPreparation.t() | CommandOutcome.t()

  @spec prepare([binary()]) ::
          {:ok, prepared()} | {:error, CommandOutcome.t() | :entropy_unavailable}
  def prepare(argv) do
    with {:ok, run_ref} <- CommandRunRef.generate() do
      prepare_with_ref(argv, run_ref, CommandRuntime.standalone())
    end
  end

  @doc "Executes one stable command and returns its sealed terminal outcome."
  @spec dispatch([binary()]) :: {:ok, CommandOutcome.t()} | {:error, CommandOutcome.t()}
  def dispatch(argv), do: dispatch(argv, CommandRuntime.standalone())

  @doc false
  @spec dispatch([binary()], CommandRuntime.t()) ::
          {:ok, CommandOutcome.t()} | {:error, CommandOutcome.t()}
  def dispatch(argv, %CommandRuntime{} = runtime) do
    if CommandRuntime.valid?(runtime) do
      case CommandEntry.open(argv, :standalone) do
        {:ok, %CommandEntry{envelope_path: envelope_path} = entry}
        when is_binary(envelope_path) ->
          {:error,
           arguments_outcome(entry.arguments, entry.run_ref, :arguments, :invalid_arguments)}

        {:ok, %CommandEntry{arguments: %{command: :repl}} = entry} ->
          {:error, outcome(:unknown, entry.run_ref, :arguments, :invalid_command)}

        {:ok, %CommandEntry{} = entry} ->
          dispatch_entry(entry, runtime)

        {:error, %CommandEntry{} = entry} ->
          entry_failure(entry)
      end
    else
      {:error, outcome(:unknown, generated_or_safe_ref(), :internal, :internal_error)}
    end
  end

  def dispatch(_argv, _runtime),
    do: {:error, outcome(:unknown, generated_or_safe_ref(), :internal, :internal_error)}

  @doc false
  @spec dispatch_entry(CommandEntry.t(), CommandRuntime.t()) ::
          {:ok, CommandOutcome.t()} | {:error, CommandOutcome.t()}
  def dispatch_entry(%CommandEntry{} = entry, %CommandRuntime{} = runtime) do
    {status, outcome, _rejection} = dispatch_entry_context(entry, runtime, false)
    {status, outcome}
  end

  def dispatch_entry(%CommandEntry{} = entry, _runtime), do: startup_failure(entry)

  @doc false
  @spec dispatch_frontend_entry(CommandEntry.t(), CommandRuntime.t()) ::
          {:ok, CommandOutcome.t(), nil}
          | {:error, CommandOutcome.t(), CommandRejection.t() | nil}
  def dispatch_frontend_entry(%CommandEntry{} = entry, %CommandRuntime{} = runtime),
    do: dispatch_entry_context(entry, runtime, true)

  defp dispatch_entry_context(
         %CommandEntry{arguments: %CommandArguments{command: :repl}} = entry,
         _runtime,
         _presentation?
       ),
       do: with_rejection(one_shot_repl_failure(entry.run_ref, :invalid_command))

  defp dispatch_entry_context(
         %CommandEntry{arguments: %CommandArguments{} = arguments, rejection: nil} = entry,
         %CommandRuntime{} = runtime,
         presentation?
       ) do
    if CommandRuntime.valid?(runtime) do
      case prepare_arguments_safely(
             arguments,
             entry.run_ref,
             entry.destinations,
             runtime
           ) do
        {:ok, %CommandPreparation{} = preparation} ->
          dispatch_preparation(preparation, runtime, entry, presentation?)

        terminal ->
          with_rejection(terminal)
      end
    else
      with_rejection(startup_failure(entry))
    end
  end

  defp dispatch_entry_context(%CommandEntry{} = entry, _runtime, _presentation?),
    do: with_rejection(startup_failure(entry))

  defp dispatch_preparation(preparation, runtime, entry, true) do
    CommandRunDispatch.dispatch_frontend(preparation, runtime, entry.frontend)
  end

  defp dispatch_preparation(preparation, runtime, _entry, false),
    do: with_rejection(CommandRunDispatch.dispatch(preparation, runtime))

  defp with_rejection({status, %CommandOutcome{} = outcome}) when status in [:ok, :error],
    do: {status, outcome, nil}

  @doc false
  @spec entry_failure(CommandEntry.t()) :: {:error, CommandOutcome.t()}
  def entry_failure(
        %CommandEntry{rejection: %CommandRejection{command: :repl} = rejection} = entry
      ),
      do: one_shot_repl_failure(entry.run_ref, rejection.code)

  def entry_failure(%CommandEntry{rejection: %CommandRejection{} = rejection} = entry),
    do: {:error, outcome(rejection.command, entry.run_ref, :arguments, rejection.code)}

  @doc false
  @spec startup_failure(CommandEntry.t()) :: {:error, CommandOutcome.t()}
  def startup_failure(%CommandEntry{arguments: %CommandArguments{command: :repl}} = entry),
    do: one_shot_repl_failure(entry.run_ref, :invalid_command)

  def startup_failure(%CommandEntry{
        arguments: %CommandArguments{} = arguments,
        run_ref: run_ref
      }),
      do: {:error, arguments_outcome(arguments, run_ref, :internal, :internal_error)}

  def startup_failure(%CommandEntry{} = entry), do: entry_failure(entry)

  @doc false
  @spec run_startup_failure() :: {:error, CommandOutcome.t()}
  def run_startup_failure do
    run_ref = generated_or_safe_ref()

    {:error,
     CommandOutcome.run_error(
       run_ref,
       diagnostic(:internal, :internal_error),
       CommandDestination.requested_artifact_state(%{})
     )}
  end

  @doc "Authorizes a prepared run's destinations at the phase-6 boundary."
  @spec preflight(CommandPreparation.t()) ::
          {:ok, PublicationAuthority.t()} | {:error, CommandOutcome.t()}
  def preflight(preparation), do: CommandDestination.preflight(preparation)

  defp prepare_with_ref(argv, run_ref, runtime) do
    case CommandParser.parse(argv) do
      {:ok, %CommandArguments{command: :repl}} ->
        one_shot_repl_failure(run_ref, :invalid_command)

      {:ok, %CommandArguments{frontend_options: []} = arguments} ->
        prepare_arguments_safely(
          arguments,
          run_ref,
          CommandDestination.capture(arguments.options),
          runtime
        )

      {:ok, %CommandArguments{} = arguments} ->
        {:error, arguments_outcome(arguments, run_ref, :arguments, :invalid_arguments)}

      {:error, %CommandRejection{command: :repl} = rejection} ->
        one_shot_repl_failure(run_ref, rejection.code)

      {:error, %CommandRejection{} = rejection} ->
        {:error, outcome(rejection.command, run_ref, :arguments, rejection.code)}
    end
  rescue
    _exception -> {:error, outcome(:unknown, run_ref, :internal, :internal_error)}
  catch
    _kind, _reason -> {:error, outcome(:unknown, run_ref, :internal, :internal_error)}
  end

  defp one_shot_repl_failure(run_ref, :invalid_command),
    do: {:error, outcome(:unknown, run_ref, :arguments, :invalid_command)}

  defp one_shot_repl_failure(run_ref, _rejection_code),
    do: {:error, outcome(:unknown, run_ref, :arguments, :invalid_arguments)}

  defp prepare_arguments_safely(%CommandArguments{} = arguments, run_ref, destinations, runtime) do
    case arguments.command do
      command when command in [:validate, :run] ->
        CommandAcquisition.prepare(arguments, run_ref, destinations, runtime)

      :help ->
        {:ok,
         CommandOutcome.success(
           :help,
           run_ref,
           CommandContract.help_result(arguments.options.topic, arguments.frontend)
         )}

      :version ->
        {:ok, CommandOutcome.success(:version, run_ref, CommandContract.version_result())}

      :doctor ->
        CommandDoctor.dispatch(arguments, run_ref, runtime)

      :models ->
        models_outcome(arguments, run_ref)

      :init ->
        CommandInitializer.initialize(arguments.directory, run_ref)
    end
  rescue
    _exception -> {:error, arguments_outcome(arguments, run_ref, :internal, :internal_error)}
  catch
    _kind, _reason ->
      {:error, arguments_outcome(arguments, run_ref, :internal, :internal_error)}
  end

  defp models_outcome(
         %CommandArguments{options: %{host_config: host_config}} = arguments,
         run_ref
       ) do
    case CommandAcquisition.with_catalog(host_config, fn _host, catalog ->
           {:ok,
            CommandOutcome.success(:models, run_ref, %{
              "installations" => InstallationCatalog.public_installations(catalog)
            })}
         end) do
      {:error, %CommandDiagnostic{} = diagnostic} ->
        {:error, arguments_outcome(arguments, run_ref, diagnostic)}

      result ->
        result
    end
  end

  defp generated_or_safe_ref do
    case CommandRunRef.generate() do
      {:ok, run_ref} -> run_ref
      {:error, :entropy_unavailable} -> @fallback_run_ref
    end
  end

  defp outcome(command, run_ref, phase, code),
    do: CommandOutcome.error(command, run_ref, diagnostic(phase, code))

  defp arguments_outcome(arguments, run_ref, phase, code),
    do: arguments_outcome(arguments, run_ref, diagnostic(phase, code))

  defp arguments_outcome(%CommandArguments{command: :run, options: options}, run_ref, diagnostic) do
    CommandOutcome.run_error(
      run_ref,
      diagnostic,
      CommandDestination.requested_artifact_state(options)
    )
  end

  defp arguments_outcome(%CommandArguments{} = arguments, run_ref, diagnostic),
    do: CommandOutcome.error(command_mode(arguments), run_ref, diagnostic)

  defp command_mode(%CommandArguments{command: :doctor, options: %{connect: true}}),
    do: {:doctor, :connect}

  defp command_mode(%CommandArguments{command: command}), do: command

  defp diagnostic(phase, code), do: CommandDiagnostic.new!(phase, code)
end
