defmodule PtcRunner.Kernel.CommandInitializer do
  @moduledoc """
  Bounded, no-replace publication of the stable application scaffold.

  The complete four-file scaffold is rendered and prepared from memory before
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
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.StrictJSON

  @main_clj """
  (ns main)

  (defn run [input]
    (return {"greeting" (str "hello " (get input "name"))}))
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
      "value": {"name": "world"}
    }
  }
  """

  @project """
  {
    "$schema": "https://ptc-runner.dev/schemas/ptc-project-config.schema.json",
    "kind": "ptc-project",
    "version": 1,
    "application": {
      "path": "ptc.json"
    },
    "artifacts": {
      "root": ".ptc",
      "trace": true,
      "inspection": false,
      "result": false,
      "envelope": true
    },
    "viewer": {
      "port": 4123,
      "open": true,
      "repl": true,
      "private": false
    }
  }
  """

  @gitignore """
  .ptc/
  .ptc-private-*
  .ptc-private-result-*
  """

  # Deliberately a routing card, not a manual: every pointer is a command
  # served by the installed executable, so it cannot describe another version.
  @agents_md """
  # AGENTS.md

  This project runs on the `ptc` executable. Ask the installed binary for the
  exact contract instead of guessing; its answers always match its own version
  and need no network.

  ## Find the exact contract

  - `ptc help` lists every command; `ptc help COMMAND` gives its switches.
  - `ptc docs` lists every shipped document; read `ptc docs agent-guide` first.
  - `ptc repl -e '(doc "name")'` documents one function, and
    `ptc repl -e '(apropos "term")'` searches the available language surface.

  ## Files here

  - `ptc.json` — the application: workflow, input, providers, missions, limits.
  - `main.clj` — the PTC-Lisp component the workflow entry calls.
  - `ptc-project.json` — local paths and artifact settings. Pass this document
    to commands so they do not depend on the current directory.

  ## Working loop

  ```console
  ptc validate ptc-project.json
  ptc repl --project ptc-project.json -e '(main/run {"name" "world"})'
  ptc run ptc-project.json --envelope out.json
  ```

  Parse `out.json` rather than scraping stdout. Keep credentials in an exact
  environment file passed with `--env-file`; never place a secret in
  `ptc.json`, in a component, or in a prompt.
  """

  @documents %{
    "AGENTS.md" => @agents_md,
    ".gitignore" => @gitignore,
    "main.clj" => @main_clj,
    "ptc.json" => @manifest,
    "ptc-project.json" => @project
  }
  @created ["AGENTS.md", ".gitignore", "main.clj", "ptc.json", "ptc-project.json"]
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
         :ok <- preflight_target(anchored_target),
         :ok <- PrivateDirectory.preflight(anchored_target),
         {:ok, state} <- create_staging(anchored_target),
         result <- assemble_and_publish(state, anchored_target, publisher, fault_hook) do
      case result do
        :ok ->
          {:ok, CommandOutcome.success(:init, run_ref, %{"created" => @created})}

        {:error, failed_state} ->
          cleanup(failed_state)
          initialization_error(run_ref)

        {:error, reason, failed_state} ->
          cleanup(failed_state)
          initialization_error(run_ref, reason)
      end
    else
      failure -> initialization_error(run_ref, failure)
    end
  rescue
    _exception -> initialization_error(run_ref)
  catch
    _kind, _reason -> initialization_error(run_ref)
  end

  def initialize(_target, run_ref, _opts) when is_binary(run_ref),
    do: initialization_error(run_ref)

  defp preflight_target(target) do
    case File.lstat(target) do
      {:ok, _stat} -> {:error, :initialization_target_exists}
      {:error, :enoent} -> preflight_parent(Path.dirname(target))
      {:error, _reason} -> {:error, :initialization_parent_unusable}
    end
  end

  defp preflight_parent(parent) do
    case File.stat(parent) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _not_directory} -> {:error, :initialization_parent_unusable}
      {:error, :enoent} -> {:error, :initialization_parent_missing}
      {:error, _reason} -> {:error, :initialization_parent_unusable}
    end
  end

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
             ApplicationPackage.request_memory(
               "ptc.json",
               Map.take(@documents, ["main.clj", "ptc.json"]),
               result_projection: :json
             ),
           {:ok, prepared} <- RunCoordinator.prepare(request, catalog),
           :ok <- PreparedRun.close(prepared),
           {:ok, project} <- StrictJSON.decode(@project),
           {:ok, root} <- JSV.build(ProjectConfig.schema(), atoms: false, warnings: :silent),
           {:ok, _validated} <- JSV.validate(project, root, cast: false) do
        :ok
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
         :ok <- verify_complete(state) do
      case invoke_publisher(publisher, state.path, target) do
        :ok -> :ok
        {:error, :publication_status_unknown} -> recover_publication_status(state, target)
        {:error, reason} -> {:error, reason, state}
      end
    else
      _failure -> {:error, state}
    end
  end

  defp recover_publication_status(state, target) do
    case verify_published_complete(state, target) do
      :ok -> :ok
      {:error, _reason} -> {:error, state}
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

  defp verify_published_complete(state, target) do
    with {:error, :enoent} <- File.lstat(state.path),
         {:ok, identity} when identity == state.identity <- owned_directory_identity(target),
         {:ok, names} <- File.ls(target),
         true <- Enum.sort(names) == Enum.sort(@created),
         true <- Enum.all?(state.children, &published_child_matches?(state, target, &1)),
         {:ok, identity} when identity == state.identity <- owned_directory_identity(target) do
      :ok
    else
      _changed_or_uncommitted -> {:error, :publication_unverified}
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

  defp published_child_matches?(state, target, {name, identity}) do
    case owned_file_identity(Path.join(target, name), state.identity) do
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
      {:error, :publication_status_unknown} = unknown -> unknown
      {:error, :collision} = collision -> collision
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

  defp initialization_error(run_ref, reason \\ nil) do
    diagnostic = CommandDiagnostic.new!(:publication, initialization_code(reason))
    {:error, CommandOutcome.error(:init, run_ref, diagnostic)}
  end

  defp initialization_code({:error, reason}), do: initialization_code(reason)
  defp initialization_code(:initialization_target_exists), do: :initialization_target_exists
  defp initialization_code(:collision), do: :initialization_target_exists
  defp initialization_code(:initialization_parent_missing), do: :initialization_parent_missing

  defp initialization_code(reason)
       when reason in [
              :initialization_parent_unusable,
              :private_directory_parent_unavailable,
              :private_directory_parent_unsafe
            ],
       do: :initialization_parent_unusable

  defp initialization_code(_reason), do: :initialization_failed
end
