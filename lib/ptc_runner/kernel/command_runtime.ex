defmodule PtcRunner.Kernel.CommandRuntime do
  @moduledoc """
  Sealed frontend-owned choices for shared command dispatch.

  The value contains only VM policy and callbacks. It never contains a host
  document, application source, provider credential, or artifact destination.
  Environment setup is invoked only when inert preparation proves that a
  selected installation uses an environment credential.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandDiagnostic

  @enforce_keys [
    :provider_application_mode,
    :authorization_targets,
    :authorization_notifier,
    :environment_setup,
    :attestation
  ]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type t :: %__MODULE__{
          provider_application_mode: :host_owned | :command_vm,
          authorization_targets: [binary()],
          authorization_notifier: (binary() -> any()) | nil,
          environment_setup: (-> :ok | {:error, term()}) | nil,
          attestation: binary()
        }

  @spec standalone() :: t()
  def standalone do
    {:ok, runtime} = new(provider_application_mode: :command_vm)
    runtime
  end

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_command_runtime}
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    keys = Keyword.keys(opts)

    if Keyword.keyword?(opts) and
         keys --
           [
             :provider_application_mode,
             :authorization_targets,
             :authorization_notifier,
             :environment_setup
           ] == [] and length(keys) == MapSet.size(MapSet.new(keys)) do
      runtime = %__MODULE__{
        provider_application_mode: Keyword.get(opts, :provider_application_mode, :host_owned),
        authorization_targets: Keyword.get(opts, :authorization_targets, []),
        authorization_notifier: Keyword.get(opts, :authorization_notifier),
        environment_setup: Keyword.get(opts, :environment_setup),
        attestation: <<>>
      }

      if fields_valid?(runtime) do
        {:ok, %{runtime | attestation: Attestation.attest(__MODULE__, payload(runtime))}}
      else
        {:error, :invalid_command_runtime}
      end
    else
      {:error, :invalid_command_runtime}
    end
  end

  def new(_opts), do: {:error, :invalid_command_runtime}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{attestation: attestation} = runtime),
    do:
      fields_valid?(runtime) and
        Attestation.valid?(__MODULE__, payload(runtime), attestation)

  def valid?(_runtime), do: false

  @doc false
  @spec setup_environment(t()) ::
          :ok | {:error, :environment_setup_failed | :environment_file_unavailable}
  def setup_environment(%__MODULE__{environment_setup: nil} = runtime) do
    if valid?(runtime), do: :ok, else: {:error, :environment_setup_failed}
  end

  def setup_environment(%__MODULE__{} = runtime) do
    if valid?(runtime) do
      case runtime.environment_setup.() do
        :ok -> :ok
        # The dotenv attachment classifies its own failure, because only it
        # knows the operator named the file. Everything else stays
        # undifferentiated.
        {:error, :environment_file_unavailable} -> {:error, :environment_file_unavailable}
        _failure -> {:error, :environment_setup_failed}
      end
    else
      {:error, :environment_setup_failed}
    end
  rescue
    _exception -> {:error, :environment_setup_failed}
  catch
    _kind, _reason -> {:error, :environment_setup_failed}
  end

  def setup_environment(_runtime), do: {:error, :environment_setup_failed}

  @doc """
  Runs environment setup and classifies a named environment file that failed.

  Commands share this so `run` and `doctor` answer a bad `--env-file`, or a
  project's `host.env_file`, with the same code instead of one of them
  reporting an internal failure.
  """
  @spec setup_environment_diagnostic(t()) :: :ok | {:error, CommandDiagnostic.t() | atom()}
  def setup_environment_diagnostic(runtime) do
    case setup_environment(runtime) do
      :ok ->
        :ok

      {:error, :environment_file_unavailable} ->
        {:error, CommandDiagnostic.new!(:local_preflight, :environment_file_unavailable)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec with_environment(t(), (-> :ok | {:error, term()})) ::
          {:ok, t()} | {:error, :invalid_command_runtime}
  def with_environment(%__MODULE__{} = runtime, setup) when is_function(setup, 0) do
    if valid?(runtime) do
      existing = runtime.environment_setup

      combined = fn ->
        with :ok <- setup.(), do: invoke_existing(existing)
      end

      new(
        provider_application_mode: runtime.provider_application_mode,
        authorization_targets: runtime.authorization_targets,
        authorization_notifier: runtime.authorization_notifier,
        environment_setup: combined
      )
    else
      {:error, :invalid_command_runtime}
    end
  end

  def with_environment(_runtime, _setup), do: {:error, :invalid_command_runtime}

  defp fields_valid?(runtime) do
    Enum.sort(Map.keys(runtime)) == @field_keys and
      runtime.provider_application_mode in [:host_owned, :command_vm] and
      is_list(runtime.authorization_targets) and
      length(runtime.authorization_targets) <= 128 and
      runtime.authorization_targets == Enum.uniq(runtime.authorization_targets) and
      Enum.all?(runtime.authorization_targets, &valid_name?/1) and
      authorization_pair_valid?(runtime.authorization_targets, runtime.authorization_notifier) and
      (is_nil(runtime.environment_setup) or is_function(runtime.environment_setup, 0))
  end

  defp authorization_pair_valid?([], nil), do: true
  defp authorization_pair_valid?([_name | _rest], notifier), do: is_function(notifier, 1)
  defp authorization_pair_valid?(_targets, _notifier), do: false

  defp valid_name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..128 and String.valid?(name) and
        Regex.match?(~r/\A[a-z][a-z0-9._-]{0,127}\z/, name)

  defp invoke_existing(nil), do: :ok
  defp invoke_existing(callback), do: callback.()

  defp payload(runtime),
    do:
      {runtime.provider_application_mode, runtime.authorization_targets,
       runtime.authorization_notifier, runtime.environment_setup}
end
