defmodule PtcRunner.Kernel.CommandEntry do
  @moduledoc """
  Closed result of the frontend-owned command entry step.

  Entry generates the command reference, parses exactly once, and validates an
  envelope destination against every derivable artifact target before startup.
  A rejected entry retains no caller-owned destination or unknown switch text.
  """

  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandDestination
  alias PtcRunner.Kernel.CommandParser
  alias PtcRunner.Kernel.CommandRejection
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.DestinationIdentity
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.PublicationAuthority

  @fallback_run_ref "cmd-00000000000000000000000000"
  @enforce_keys [:run_ref, :frontend, :arguments, :rejection, :envelope_path, :destinations]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          run_ref: binary(),
          frontend: :standalone | :mix,
          arguments: CommandArguments.t() | nil,
          rejection: CommandRejection.t() | nil,
          envelope_path: binary() | nil,
          destinations: {map(), [atom()]} | nil
        }

  @spec open([binary()], :standalone | :mix) :: {:ok, t()} | {:error, t()}
  def open(argv, frontend) when frontend in [:standalone, :mix] do
    run_ref = generated_or_safe_ref()
    open_safely(argv, frontend, run_ref)
  end

  def open(_argv, frontend) do
    frontend = if frontend in [:standalone, :mix], do: frontend, else: :standalone
    run_ref = generated_or_safe_ref()
    {:error, rejected(run_ref, frontend, CommandRejection.generic(:unknown, :invalid_arguments))}
  end

  @doc false
  @spec open_with_ref([binary()], :standalone | :mix, binary()) :: {:ok, t()} | {:error, t()}
  def open_with_ref(argv, frontend, run_ref)
      when frontend in [:standalone, :mix] and is_binary(run_ref) do
    if CommandRunRef.valid?(run_ref),
      do: open_safely(argv, frontend, run_ref),
      else:
        {:error,
         rejected(
           @fallback_run_ref,
           frontend,
           CommandRejection.generic(:unknown, :invalid_arguments)
         )}
  end

  defp open_safely(argv, frontend, run_ref) do
    case CommandParser.parse(argv, frontend) do
      {:ok, %CommandArguments{} = arguments} ->
        finish(arguments, run_ref, frontend)

      {:error, %CommandRejection{} = rejection} ->
        {:error, rejected(run_ref, frontend, rejection)}
    end
  rescue
    _exception ->
      {:error,
       rejected(run_ref, frontend, CommandRejection.generic(:unknown, :invalid_arguments))}
  catch
    _kind, _reason ->
      {:error,
       rejected(run_ref, frontend, CommandRejection.generic(:unknown, :invalid_arguments))}
  end

  defp finish(arguments, run_ref, frontend) do
    destinations = CommandDestination.capture(arguments.options)

    case anchor_entry_paths(arguments) do
      {:ok, arguments} ->
        finish(arguments, destinations, run_ref, frontend)

      _invalid ->
        {:error,
         rejected(
           run_ref,
           frontend,
           CommandRejection.generic(arguments.command, :invalid_arguments)
         )}
    end
  end

  defp anchor_entry_paths(arguments) do
    with {:ok, arguments} <- anchor_init_target(arguments),
         do: anchor_env_file(arguments)
  end

  defp anchor_env_file(%CommandArguments{frontend_options: options} = arguments) do
    case Keyword.fetch(options, :env_file) do
      :error ->
        {:ok, arguments}

      {:ok, path} ->
        with {:ok, path} <- anchor_file(path) do
          {:ok, %{arguments | frontend_options: Keyword.replace!(options, :env_file, path)}}
        end
    end
  end

  defp finish(arguments, destinations, run_ref, frontend) do
    case Keyword.fetch(arguments.frontend_options, :envelope) do
      :error ->
        {:ok, accepted(run_ref, frontend, arguments, nil, destinations)}

      {:ok, envelope} ->
        with {:ok, envelope} <- anchor_file(envelope),
             :ok <- distinct?(arguments, destinations, run_ref, envelope) do
          arguments = %{
            arguments
            | frontend_options: Keyword.delete(arguments.frontend_options, :envelope)
          }

          {:ok, accepted(run_ref, frontend, arguments, envelope, destinations)}
        else
          {:error, :invalid_destination} ->
            {:error,
             rejected(
               run_ref,
               frontend,
               CommandRejection.invalid_destination(
                 arguments.command,
                 :envelope,
                 frontend
               )
             )}

          {:error, {:destination_collision, key}} ->
            destination_collision(arguments, run_ref, frontend, key, :envelope)

          {:error, :init_destination_collision} ->
            {:error,
             rejected(
               run_ref,
               frontend,
               CommandRejection.init_destination_collision(frontend)
             )}
        end
    end
  end

  defp distinct?(%CommandArguments{command: :run}, {destinations, _failures}, run_ref, envelope) do
    candidates =
      [:output, :private_output, :inspect]
      |> Enum.flat_map(&destination_option_candidate(destinations, &1))
      |> Kernel.++(derived_trace_paths(destinations, run_ref))
      |> Kernel.++(derived_recovery_path(destinations, run_ref))

    case Enum.find(candidates, fn {_key, path} ->
           DestinationIdentity.key(path) == DestinationIdentity.key(envelope)
         end) do
      {key, _path} -> {:error, {:destination_collision, key}}
      nil -> :ok
    end
  end

  defp distinct?(
         %CommandArguments{command: :init, directory: target},
         _destinations,
         _run_ref,
         envelope
       ) do
    case DestinationIdentity.within?(envelope, target) do
      false -> :ok
      _collision_or_invalid -> {:error, :init_destination_collision}
    end
  end

  defp distinct?(_arguments, _destinations, _run_ref, _envelope), do: :ok

  defp destination_collision(arguments, run_ref, frontend, first, second) do
    {:error,
     rejected(
       run_ref,
       frontend,
       CommandRejection.destination_collision(arguments.command, first, second, frontend)
     )}
  end

  defp derived_trace_paths(options, run_ref) do
    case Map.fetch(options, :trace_dir) do
      {:ok, directory} ->
        case anchor_path(directory) do
          {:ok, directory} ->
            [
              {:trace_dir, Path.join(directory, run_ref <> ".jsonl")},
              {:trace_dir, Path.join(directory, run_ref <> ".private.jsonl")}
            ]

          {:error, _reason} ->
            []
        end

      :error ->
        []
    end
  end

  defp derived_recovery_path(options, run_ref) do
    case destination_option(options, :private_output) do
      [requested] ->
        [{:private_output, PublicationAuthority.recovery_path(run_ref, requested)}]

      [] ->
        []
    end
  end

  defp destination_option(options, key) do
    case Map.fetch(options, key) do
      {:ok, path} ->
        [path]

      :error ->
        []
    end
  end

  defp destination_option_candidate(options, key) do
    Enum.map(destination_option(options, key), &{key, &1})
  end

  defp anchor_init_target(%CommandArguments{command: :init, directory: directory} = arguments) do
    case anchor_path(directory) do
      {:ok, target} -> {:ok, %{arguments | directory: target}}
      {:error, _reason} = error -> error
    end
  end

  defp anchor_init_target(%CommandArguments{} = arguments), do: {:ok, arguments}

  defp anchor_file(path) when is_binary(path) and path not in ["", "-"] do
    with {:ok, path} <- anchor_path(path),
         true <- Path.basename(path) not in ["", ".", ".."] do
      {:ok, path}
    else
      _invalid -> {:error, :invalid_destination}
    end
  end

  defp anchor_file(_path), do: {:error, :invalid_destination}

  defp anchor_path(path) when is_binary(path) do
    if String.valid?(path) and not String.contains?(path, <<0>>),
      do: PrivateDirectory.anchor(path),
      else: {:error, :invalid_destination}
  end

  defp anchor_path(_path), do: {:error, :invalid_destination}

  defp accepted(run_ref, frontend, arguments, envelope_path, destinations) do
    %__MODULE__{
      run_ref: run_ref,
      frontend: frontend,
      arguments: arguments,
      rejection: nil,
      envelope_path: envelope_path,
      destinations: destinations
    }
  end

  defp rejected(run_ref, frontend, rejection) do
    %__MODULE__{
      run_ref: run_ref,
      frontend: frontend,
      arguments: nil,
      rejection: rejection,
      envelope_path: nil,
      destinations: nil
    }
  end

  defp generated_or_safe_ref do
    case CommandRunRef.generate() do
      {:ok, run_ref} -> run_ref
      {:error, :entropy_unavailable} -> @fallback_run_ref
    end
  rescue
    _exception -> @fallback_run_ref
  catch
    _kind, _reason -> @fallback_run_ref
  end
end
