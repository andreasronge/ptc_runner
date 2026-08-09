defmodule PtcRunner.Kernel.CommandEngine do
  @moduledoc """
  Shared command parser and dispatch router.

  The engine owns the single argv grammar and returns only sealed terminal
  outcomes. Cohesive acquisition, doctor, destination, and run-dispatch
  components own their respective phase ranges. Shared code never writes
  process streams, halts the VM, or renders arbitrary failures.

  Provider-free and provider-backed `run` commands complete through the same
  owner-backed execution and publication path. Provider-free runs retain
  `ExecutionSessionOwner` while omitting only the provider session.
  `doctor --connect` remains its own active operation. `models` projects only
  public installation declarations and invokes no provider runtime service.
  """

  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDestination
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandDoctor
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandParser
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRunDispatch
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunRequest

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
      run_ref = generated_or_safe_ref()

      case prepare_with_ref(argv, run_ref, runtime) do
        {:ok, %CommandPreparation{} = preparation} ->
          CommandRunDispatch.dispatch(preparation, runtime)

        terminal ->
          terminal
      end
    else
      {:error, outcome(:unknown, generated_or_safe_ref(), :internal, :internal_error)}
    end
  end

  def dispatch(_argv, _runtime),
    do: {:error, outcome(:unknown, generated_or_safe_ref(), :internal, :internal_error)}

  @doc "Authorizes a prepared run's destinations at the phase-6 boundary."
  @spec preflight(CommandPreparation.t()) ::
          {:ok, PublicationAuthority.t()} | {:error, CommandOutcome.t()}
  def preflight(preparation), do: CommandDestination.preflight(preparation)

  @doc false
  @spec request(binary(), InstallationCatalog.t(), keyword()) ::
          {:ok, RunRequest.t()} | {:error, term()}
  def request(application, catalog, options),
    do: CommandAcquisition.request(application, catalog, options)

  @doc false
  @spec catalog(binary() | nil) ::
          {:ok, PtcRunner.Kernel.HostConfig.t() | nil, InstallationCatalog.t()}
          | {:error, CommandDiagnostic.t()}
  def catalog(path), do: CommandAcquisition.catalog(path)

  defp prepare_with_ref(argv, run_ref, runtime) do
    case CommandParser.parse(argv) do
      {:ok, %CommandArguments{} = arguments} ->
        prepare_arguments_safely(
          arguments,
          run_ref,
          CommandDestination.capture(arguments.options),
          runtime
        )

      {:error, command, code} ->
        {:error, outcome(command, run_ref, :arguments, code)}
    end
  rescue
    _exception -> {:error, outcome(:unknown, run_ref, :internal, :internal_error)}
  catch
    _kind, _reason -> {:error, outcome(:unknown, run_ref, :internal, :internal_error)}
  end

  defp prepare_arguments_safely(%CommandArguments{} = arguments, run_ref, destinations, runtime) do
    case arguments.command do
      command when command in [:validate, :run] ->
        CommandAcquisition.prepare(arguments, run_ref, destinations, runtime)

      :help ->
        {:ok,
         CommandOutcome.success(
           :help,
           run_ref,
           CommandContract.help_result(arguments.options.topic)
         )}

      :version ->
        {:ok, CommandOutcome.success(:version, run_ref, CommandContract.version_result())}

      :doctor ->
        CommandDoctor.dispatch(arguments, run_ref)

      :models ->
        models_outcome(arguments, run_ref)

      :init ->
        {:error, arguments_outcome(arguments, run_ref, :internal, :internal_error)}
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

  defp diagnostic(phase, code) do
    source = if phase == :host, do: CommandSource.fixed(:host), else: nil
    CommandDiagnostic.new!(phase, code, source: source)
  end
end
