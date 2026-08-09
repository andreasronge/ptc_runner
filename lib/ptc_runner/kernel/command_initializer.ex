defmodule PtcRunner.Kernel.CommandInitializer do
  @moduledoc """
  Bounded, no-replace publication of the stable application scaffold.

  The complete two-file scaffold is rendered and prepared from memory before
  target filesystem access. Files are assembled under one owner-only sibling
  directory. A platform no-replace rename is the commit point; failures before
  it remove only identity-verified known staging entries, while success never
  triggers target rollback.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.RunCoordinator

  @main_clj """
  (ns main)

  (defn run [input]
    (return input))
  """

  @manifest """
  {
    "version": 1,
    "workflow": {
      "components": [
        {
          "id": "main",
          "path": "main.clj"
        }
      ],
      "entry": "main/run"
    },
    "input": {
      "value": {}
    }
  }
  """

  @documents %{"main.clj" => @main_clj, "ptc.json" => @manifest}
  @created ["main.clj", "ptc.json"]
  @staging_attempts 16

  @type identity ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @type state :: %{
          path: binary(),
          identity: identity(),
          children: %{binary() => identity()}
        }

  @doc false
  @spec initialize(binary(), binary(), keyword()) ::
          {:ok, CommandOutcome.t()} | {:error, CommandOutcome.t()}
  def initialize(target, run_ref, opts \\ [])

  def initialize(target, run_ref, opts)
      when is_binary(target) and is_binary(run_ref) and is_list(opts) do
    with {:ok, publisher, fault_hook} <- options(opts),
         :ok <- validate_scaffold(),
         {:ok, anchored_target} <- PrivateDirectory.anchor(target),
         anchored_target = trim_trailing_separators(anchored_target),
         :ok <- PrivateDirectory.preflight(anchored_target),
         {:ok, state} <- create_staging(anchored_target),
         result <- assemble_and_publish(state, anchored_target, publisher, fault_hook) do
      case result do
        :ok ->
          {:ok, CommandOutcome.success(:init, run_ref, %{"created" => @created})}

        {:error, failed_state} ->
          cleanup(failed_state)
          initialization_error(run_ref)
      end
    else
      _failure -> initialization_error(run_ref)
    end
  rescue
    _exception -> initialization_error(run_ref)
  catch
    _kind, _reason -> initialization_error(run_ref)
  end

  def initialize(_target, run_ref, _opts) when is_binary(run_ref),
    do: initialization_error(run_ref)

  defp options(opts) do
    keys = Keyword.keys(opts)

    if Keyword.keyword?(opts) and keys -- [:publisher, :fault_hook] == [] and
         length(keys) == MapSet.size(MapSet.new(keys)) do
      publisher = Keyword.get(opts, :publisher, &publish_directory/2)
      fault_hook = Keyword.get(opts, :fault_hook, fn _stage, _context -> :ok end)

      if is_function(publisher, 2) and is_function(fault_hook, 2),
        do: {:ok, publisher, fault_hook},
        else: {:error, :invalid_initializer_options}
    else
      {:error, :invalid_initializer_options}
    end
  end

  defp validate_scaffold do
    case InstallationCatalog.new() do
      {:ok, catalog} -> validate_scaffold(catalog)
      {:error, _reason} -> {:error, :invalid_scaffold}
    end
  end

  defp validate_scaffold(catalog) do
    result =
      with {:ok, request} <-
             ApplicationPackage.request_memory("ptc.json", @documents, result_projection: :json),
           {:ok, prepared} <- RunCoordinator.prepare(request, catalog) do
        PreparedRun.close(prepared)
      end

    InstallationCatalog.close(catalog)
    if result == :ok, do: :ok, else: {:error, :invalid_scaffold}
  end

  defp create_staging(target), do: create_staging(target, @staging_attempts)

  defp create_staging(_target, 0), do: {:error, :staging_unavailable}

  defp create_staging(target, attempts) do
    {staging, _child} = PrivateDirectory.temporary_sibling(target, "unused")

    case PrivateDirectory.create(staging) do
      :ok ->
        case owned_directory_identity(staging) do
          {:ok, identity} -> {:ok, %{path: staging, identity: identity, children: %{}}}
          {:error, _reason} -> {:error, :staging_unavailable}
        end

      {:error, :private_directory_creation_failed} ->
        create_staging(target, attempts - 1)

      {:error, _reason} ->
        {:error, :staging_unavailable}
    end
  end

  defp assemble_and_publish(state, target, publisher, fault_hook) do
    case invoke_fault(fault_hook, :after_staging_created, state, target) do
      :ok ->
        case write_children(state, target, fault_hook, @created) do
          {:ok, complete_state} ->
            publish_complete(complete_state, target, publisher, fault_hook)

          {:error, failed_state} ->
            {:error, failed_state}
        end

      {:error, _reason} ->
        {:error, state}
    end
  end

  defp publish_complete(state, target, publisher, fault_hook) do
    with :ok <- verify_complete(state),
         :ok <- invoke_fault(fault_hook, :before_publish, state, target),
         :ok <- verify_complete(state),
         :ok <- invoke_publisher(publisher, state.path, target) do
      :ok
    else
      _failure -> {:error, state}
    end
  end

  defp write_children(state, _target, _fault_hook, []), do: {:ok, state}

  defp write_children(state, target, fault_hook, [name | rest]) do
    case write_child(state, target, fault_hook, name, Map.fetch!(@documents, name)) do
      {:ok, state} ->
        case invoke_fault(fault_hook, {:after_child_written, name}, state, target) do
          :ok -> write_children(state, target, fault_hook, rest)
          {:error, _reason} -> {:error, state}
        end

      {:error, state} ->
        {:error, state}
    end
  end

  defp write_child(state, target, fault_hook, name, bytes) do
    with :ok <- verify_staging(state),
         path = Path.join(state.path, name),
         {:ok, :ok} <-
           File.open(path, [:write, :exclusive, :binary], fn device ->
             split = div(byte_size(bytes), 2)
             <<first::binary-size(^split), second::binary>> = bytes

             with :ok <- IO.binwrite(device, first),
                  :ok <-
                    invoke_fault(fault_hook, {:during_child_write, name}, state, target),
                  :ok <- IO.binwrite(device, second),
                  do: :file.sync(device)
           end),
         :ok <- File.chmod(path, 0o600),
         {:ok, identity} <- owned_file_identity(path, state.identity) do
      {:ok, put_in(state.children[name], identity)}
    else
      _failure -> {:error, capture_known_child(state, name)}
    end
  end

  defp capture_known_child(state, name) do
    path = Path.join(state.path, name)

    case owned_file_identity(path, state.identity) do
      {:ok, identity} -> put_in(state.children[name], identity)
      {:error, _reason} -> state
    end
  end

  defp verify_complete(state) do
    with :ok <- verify_staging(state),
         {:ok, names} <- File.ls(state.path),
         true <- Enum.sort(names) == Enum.sort(@created),
         true <- Enum.all?(state.children, &child_matches?(state, &1)) do
      :ok
    else
      _failure -> {:error, :staging_changed}
    end
  end

  defp verify_staging(state) do
    case owned_directory_identity(state.path) do
      {:ok, identity} when identity == state.identity -> :ok
      _changed -> {:error, :staging_changed}
    end
  end

  defp child_matches?(state, {name, identity}) do
    case owned_file_identity(Path.join(state.path, name), state.identity) do
      {:ok, current} -> current == identity
      {:error, _reason} -> false
    end
  end

  defp cleanup(state) do
    if verify_staging(state) == :ok do
      Enum.each(state.children, fn {name, identity} ->
        path = Path.join(state.path, name)

        if verify_staging(state) == :ok and child_matches?(state, {name, identity}) do
          File.rm(path)
        end
      end)

      if verify_staging(state) == :ok, do: File.rmdir(state.path)
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp invoke_fault(fault_hook, stage, state, target) do
    case fault_hook.(stage, %{staging: state.path, target: target}) do
      :ok -> :ok
      _failure -> {:error, :injected_failure}
    end
  rescue
    _exception -> {:error, :injected_failure}
  catch
    _kind, _reason -> {:error, :injected_failure}
  end

  defp invoke_publisher(publisher, staging, target) do
    case publisher.(staging, target) do
      :ok -> :ok
      _failure -> {:error, :publication_failed}
    end
  rescue
    _exception -> {:error, :publication_failed}
  catch
    _kind, _reason -> {:error, :publication_failed}
  end

  defp publish_directory(staging, target) do
    launcher = Module.concat(["PtcRunnerLauncher"])

    if Code.ensure_loaded?(launcher) and
         function_exported?(launcher, :publish_directory_noreplace, 2) do
      launcher.publish_directory_noreplace(staging, target)
    else
      {:error, :unsupported_platform}
    end
  end

  defp trim_trailing_separators(path) when byte_size(path) > 1 do
    if :binary.last(path) == ?/ do
      path
      |> binary_part(0, byte_size(path) - 1)
      |> trim_trailing_separators()
    else
      path
    end
  end

  defp trim_trailing_separators(path), do: path

  defp owned_directory_identity(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory, mode: mode} = stat}
      when Bitwise.band(mode, 0o077) == 0 ->
        {:ok, identity(stat)}

      _invalid ->
        {:error, :staging_changed}
    end
  end

  defp owned_file_identity(path, {_major, _minor, _inode, uid}) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, uid: ^uid} = stat} -> {:ok, identity(stat)}
      _invalid -> {:error, :staging_changed}
    end
  end

  defp identity(stat),
    do: {stat.major_device, stat.minor_device, stat.inode, stat.uid}

  defp initialization_error(run_ref) do
    diagnostic = CommandDiagnostic.new!(:publication, :initialization_failed)
    {:error, CommandOutcome.error(:init, run_ref, diagnostic)}
  end
end
