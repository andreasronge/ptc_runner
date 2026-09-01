defmodule PtcRunner.ReplFrontend do
  @moduledoc """
  Starts a direct workflow PTC-Lisp REPL or a fixed code-owned analysis
  profile.

      ptc repl
      ptc repl -e "(+ 1 2)" -e "(+ *1 3)"
      ptc repl -l setup.clj
      ptc repl script.clj
      ptc repl -
      ptc repl --manifest ptc.json
      ptc repl --manifest ptc.json --host-config ptc-host.json
      ptc repl --project ptc-project.json --mission review
      ptc repl --manifest ptc.json --host-config ptc-host.json --mission review
      ptc repl --manifest ptc.json --inspect-only
      ptc repl --project ptc-project.json --inspect-only --mission analysis
      ptc repl --manifest ptc.json --trace trace.jsonl
      ptc repl --profile run-analysis-v1 --resource traces=tmp/traces
      ptc repl --profile private-run-analysis-v2 \
        --resource traces=tmp/traces \
        --resource inspection=tmp/inspection \
        --private-terminal
      ptc repl --profile private-run-analysis-v2 \
        --resource traces=tmp/traces \
        --resource inspection=tmp/inspection \
        --private-unattended --format jsonl -e '(analysis/runs {})'
      ptc repl --profile private-run-catalog-v1 \
        --resource traces=tmp/traces \
        --resource inspection=tmp/inspection \
        --private-unattended --format jsonl -e '(analysis/catalog {})'
      ptc repl --describe-profile run-analysis-v1

  Options:

    * `-e, --eval` — evaluate an expression; repeat to preserve definitions and
      `*1`/`*2`/`*3` history;
    * `-l, --load` — evaluate a setup file before expressions or interaction;
    * `-m, --manifest` — reuse a strict Kernel manifest's workflow bundle,
      capabilities, limits, input, labels, and event policy;
    * `--mission` — evaluate one manifest mission directly, with only its
      components, data, direct capabilities, and provider dependency closure;
    * `--inspect-only` — compile the selected environment and inspect it. A
      project-declared host is decoded only for installed limit ceilings;
      credentials, providers, input, traces, and private-session authority are
      not acquired;
    * `--host-config` — manifest-only trusted provider installation document;
    * `-t, --trace` — append this session's canonical events to a JSONL file;
    * `--profile` — select a code-owned mission session profile;
    * `--resource NAME=VALUE` — supply a required profile resource; repeatable;
    * `--run RUN_ID` — select an exact run for `private-run-analysis-v2`;
      repeat one through sixteen times to admit one bounded cohort;
    * `--session-trace-dir` — existing output directory for a profile session's
      separate canonical trace;
    * `--output` / `--private-output` — atomically publish the value of exactly
      one non-interactive public/private profile evaluation;
    * `--private-terminal` — explicitly authorize an attached terminal as the
      private output sink required by a private analysis profile;
    * `--private-unattended` — explicitly authorize this command's own streams
      as that sink instead, admitting `-e`/`--load`/script/stdin and
      `--format jsonl`. Mutually exclusive with `--private-terminal`;
    * `--format clojure|jsonl` — choose human output or non-interactive
      profile-mode JSON Lines;
    * `--preview-chars COUNT` — set the structural preview character ceiling
      for direct, manifest, and profile human output (64–65536; default 2048);
    * `--continue-on-error` — evaluate later repeated `--eval` forms after a
      recoverable profile evaluation error, then exit unsuccessfully;
    * `--describe-profile` — print a safe static profile contract;
    * `-h, --help` — print this help without loading files or providers.

  A positional file runs as one script. `-` reads one script from standard
  input. With no script or `--eval`, the task starts an interactive multi-line
  REPL; `:quit` exits it. That line loop receives the same dedicated bounded
  session profile whether input is attached or piped. A lone `--load` is setup
  for the loop; repeated `--eval`, scripts, explicit `-` stdin, and loads that
  precede those inputs retain ordinary effective limits.

  Direct interactive sessions widen only their session lifetime and retained
  normal-event capacity. Interactive manifest and mission sessions default
  omitted session-lifetime and retained-event limits to installed host ceilings
  while preserving explicit narrower values. Every session keeps one finite
  absolute deadline, including time spent at the prompt; its owner closes
  provider resources at expiry without waiting for another form.

  An interactive workflow REPL attached to a terminal runs under the Erlang
  line editor, so emacs key bindings, arrow-key history, and reverse search
  work, `Ctrl+D` deletes forward rather than exiting, and `Ctrl+C` opens the
  BEAM break menu. A direct session persists its history under the user cache
  directory; a manifest session, which can carry a private event policy, keeps
  history in memory. Profile sessions and every non-terminal input path keep
  the plain reader, where `Ctrl+D` still ends input.

  Direct sessions and manifest sessions without `--mission` evaluate the
  workflow environment. A manifest mission session evaluates a fresh serialized
  mission continuation and exposes no workflow or model route. Profile mode
  evaluates one serialized mission continuation over the exact resources
  declared by its closed profile. Its analysis trace is atomically published
  outside captured private resources; without `--session-trace-dir`, the task
  creates and reports a private temporary output directory.

  JSONL mode is non-interactive and conditionally emits schema-version-1
  `session-started`, `evaluation`, and successfully persisted `session-closed`
  records for lifecycle stages that are reached. An unsuccessful command ends
  with `command-error`; validation failures can therefore emit that record
  alone. Profile selection and source-capture records carry the stable code
  from `PtcRunner.ProfileDiagnosticCatalog`; the outer one-shot error uses the
  same `repl/CODE`. Evaluation records contain the existing bounded public
  mission result projection and never add a raw source field. A failing command
  raises a closed frontend error; this shared module never halts the VM.
  """

  alias PtcRunner.Dotenv
  alias PtcRunner.Kernel.AnalysisDirectory
  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.AnalysisSession
  alias PtcRunner.Kernel.AnalysisSessionBuilder
  alias PtcRunner.Kernel.AnalysisTerminal
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandDiagnosticRenderer
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.DirectorySeparation
  alias PtcRunner.Kernel.InspectOnlyRepl
  alias PtcRunner.Kernel.ManifestRepl
  alias PtcRunner.Kernel.ProjectContext
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.SelectedCanonicalSource
  alias PtcRunner.Lisp.EvaluatorError
  alias PtcRunner.Lisp.NamespaceDiagnostic
  alias PtcRunner.Lisp.Result, as: LispResult
  alias PtcRunner.Lisp.ValuePreview
  alias PtcRunner.ProfileDiagnosticCatalog
  alias PtcRunner.ReplError
  alias PtcRunner.ReplLineEditor, as: LineEditor

  @spec run(CommandArguments.t(), CommandRuntime.t()) ::
          :ok | {:error, binary()} | {:error, atom(), binary()}
  def run(arguments, runtime), do: run(arguments, runtime, [])

  @doc false
  @spec run(CommandArguments.t(), CommandRuntime.t(), keyword()) ::
          :ok | {:error, binary()} | {:error, atom(), binary()}
  def run(
        %CommandArguments{
          command: :repl,
          application: script,
          ordered_options: opts,
          project: project
        },
        %CommandRuntime{} = runtime,
        frontend_opts
      ) do
    if valid_frontend_opts?(frontend_opts) and CommandRuntime.valid?(runtime) do
      {:ok, runtime} = Dotenv.attach_environment(runtime, opts)
      arguments = if is_binary(script), do: [script], else: []
      terminal_attached? = terminal_attached?(frontend_opts)

      case validate_command(opts, arguments, [], terminal_attached?) do
        {:ok, :describe} ->
          describe_profile(opts)

        {:ok, :profile} ->
          run_profile_session(
            Keyword.put(opts, :terminal_attached, terminal_attached?),
            arguments
          )

        {:ok, :inspect_only} ->
          case ProjectContext.installed_limits(project) do
            {:ok, installed_limits} ->
              opts =
                opts
                |> Keyword.put(:command_runtime, runtime)
                |> Keyword.put(:terminal_attached, terminal_attached?)
                |> Keyword.put(:installed_limits, installed_limits)

              run_inspect_only_session(opts, arguments)

            {:error, %CommandDiagnostic{} = diagnostic} ->
              fail_command_diagnostic(diagnostic)
          end

        {:ok, :manifest} ->
          opts =
            opts
            |> Keyword.put(:command_runtime, runtime)
            |> Keyword.put(:terminal_attached, terminal_attached?)

          run_manifest_session(opts, arguments)

        {:ok, :direct} ->
          run_direct_session(
            Keyword.put(opts, :terminal_attached, terminal_attached?),
            arguments
          )

        {:error, %{code: code, message: message}} ->
          command_error(opts, :cli, code, message)

        {:error, message} ->
          command_error(opts, :cli, message)
      end

      :ok
    else
      {:error, "invalid repl frontend options"}
    end
  rescue
    error in ReplError -> repl_error(error)
  end

  def run(_arguments, _runtime, _frontend_opts), do: {:error, "invalid repl frontend options"}

  @spec fail_command_diagnostic(CommandDiagnostic.t()) :: no_return()
  defp fail_command_diagnostic(diagnostic) do
    case CommandDiagnosticRenderer.render(diagnostic) do
      {:ok, rendered} -> fail(rendered)
      {:error, :invalid_command_diagnostic} -> fail("ptc repl setup failed")
    end
  end

  defp valid_frontend_opts?(opts) do
    Keyword.keyword?(opts) and Keyword.keys(opts) -- [:terminal_attached] == [] and
      length(opts) == MapSet.size(MapSet.new(Keyword.keys(opts))) and
      Keyword.get(opts, :terminal_attached, false) in [true, false]
  end

  defp repl_error(%ReplError{code: code, message: message})
       when is_atom(code) and not is_nil(code),
       do: {:error, code, message}

  defp repl_error(%ReplError{message: message}), do: {:error, message}

  defp terminal_attached?(opts),
    do: Keyword.get_lazy(opts, :terminal_attached, &AnalysisTerminal.attached?/0)

  defp validate_command(opts, arguments, invalid, terminal_attached?) do
    format = Keyword.get(opts, :format, "clojure")
    evals = Keyword.get_values(opts, :eval)
    resources = Keyword.get_values(opts, :resource)
    preview_chars = Keyword.get(opts, :preview_chars)

    with :ok <- validate_common_command(arguments, invalid, evals, format, preview_chars) do
      select_command(opts, arguments, evals, resources, format, terminal_attached?)
    end
  end

  defp validate_common_command(arguments, invalid, evals, format, preview_chars) do
    cond do
      invalid != [] ->
        {:error, "invalid ptc repl options: #{inspect(invalid)}"}

      length(arguments) > 1 ->
        {:error, "usage: ptc repl [OPTIONS] [SCRIPT|-]"}

      evals != [] and arguments != [] ->
        {:error, "cannot combine --eval with a script or stdin"}

      format not in ["clojure", "jsonl"] ->
        {:error, "invalid ptc repl format: #{inspect(format)}"}

      not is_nil(preview_chars) and preview_chars not in 64..65_536 ->
        {:error, "--preview-chars must be between 64 and 65536"}

      true ->
        :ok
    end
  end

  defp select_command(opts, arguments, evals, resources, format, terminal_attached?) do
    with :ok <- validate_mission_command(opts) do
      select_command_mode(opts, arguments, evals, resources, format, terminal_attached?)
    end
  end

  defp select_command_mode(opts, arguments, evals, resources, format, terminal_attached?) do
    cond do
      opts[:describe_profile] ->
        validate_description(opts, arguments)

      opts[:inspect_only] ->
        validate_inspect_only_command(opts, resources, format)

      opts[:profile] ->
        validate_profile_command(
          opts,
          arguments,
          evals,
          resources,
          format,
          terminal_attached?
        )

      opts[:manifest] ->
        validate_manifest_command(opts, resources, format)

      opts[:host_config] ->
        {:error, "--host-config requires --manifest"}

      resources != [] or not is_nil(opts[:session_trace_dir]) or
        Keyword.has_key?(opts, :continue_on_error) or
        Keyword.has_key?(opts, :private_terminal) or
        Keyword.has_key?(opts, :private_unattended) or Keyword.has_key?(opts, :run) ->
        {:error, "profile options require --profile"}

      format == "jsonl" ->
        {:error, "--format jsonl requires --profile or --describe-profile"}

      true ->
        {:ok, :direct}
    end
  end

  defp validate_inspect_only_command(opts, resources, format) do
    cond do
      is_nil(opts[:manifest]) ->
        {:error, "--inspect-only requires --project or --manifest"}

      resources != [] or not is_nil(opts[:session_trace_dir]) or
        Keyword.has_key?(opts, :continue_on_error) or
        Keyword.has_key?(opts, :host_config) or not is_nil(opts[:trace]) or
        Keyword.has_key?(opts, :private_terminal) or
        Keyword.has_key?(opts, :private_unattended) or Keyword.has_key?(opts, :run) or
        not is_nil(opts[:output]) or not is_nil(opts[:private_output]) or
          not is_nil(opts[:profile]) ->
        {:error, "--inspect-only cannot be combined with host, env, trace, or profile options"}

      format == "jsonl" ->
        {:error, "--format jsonl requires --profile or --describe-profile"}

      true ->
        {:ok, :inspect_only}
    end
  end

  defp validate_mission_command(opts) do
    cond do
      opts[:mission] && opts[:profile] ->
        {:error, "--mission cannot be combined with --profile"}

      opts[:mission] && opts[:describe_profile] ->
        {:error, "--mission cannot be combined with --describe-profile"}

      opts[:mission] && !opts[:manifest] ->
        {:error, "--mission requires --manifest"}

      true ->
        :ok
    end
  end

  defp validate_manifest_command(opts, resources, format) do
    cond do
      resources != [] or not is_nil(opts[:session_trace_dir]) or
          Keyword.has_key?(opts, :continue_on_error) ->
        {:error, "profile resources require --profile"}

      format == "jsonl" ->
        {:error, "--format jsonl requires --profile or --describe-profile"}

      true ->
        {:ok, :manifest}
    end
  end

  defp validate_description(opts, arguments) do
    disallowed = Keyword.keys(opts) -- [:describe_profile, :format]

    cond do
      arguments != [] ->
        {:error, "--describe-profile does not accept a script or stdin"}

      disallowed != [] ->
        {:error, "--describe-profile cannot be combined with runtime options"}

      true ->
        case AnalysisProfileRegistry.fetch(opts[:describe_profile]) do
          {:ok, _recipe} -> {:ok, :describe}
          {:error, _reason} -> {:error, unsupported_profile_message()}
        end
    end
  end

  defp validate_profile_command(
         opts,
         arguments,
         evals,
         resources,
         format,
         terminal_attached?
       ) do
    with {:ok, recipe} <- AnalysisProfileRegistry.fetch(opts[:profile]),
         :ok <- validate_selected_runs(recipe, opts),
         :ok <-
           validate_profile_combinations(
             recipe,
             opts,
             arguments,
             evals,
             resources,
             format
           ),
         :ok <-
           AnalysisProfileRegistry.authorize_frontend(recipe, %{
             input_mode: profile_input_mode(opts, arguments, evals),
             output_format: output_format(opts),
             continue_on_error: Keyword.get(opts, :continue_on_error, false),
             private_terminal: Keyword.get(opts, :private_terminal, false),
             private_unattended: Keyword.get(opts, :private_unattended, false),
             terminal_attached: terminal_attached?
           }) do
      {:ok, :profile}
    else
      {:error, :unsupported_analysis_profile} ->
        {:error, unsupported_profile_message()}

      {:error, reason}
      when reason in [
             :invalid_run_reference,
             :selected_set_limit_exceeded,
             :duplicate_selected_run
           ] ->
        {:error, ProfileDiagnosticCatalog.classify!(reason)}

      {:error, reason} when is_atom(reason) ->
        {:error, profile_frontend_error(reason)}
    end
  end

  defp describe_profile(opts) do
    {:ok, description} = AnalysisProfileRegistry.description(opts[:describe_profile])

    if output_format(opts) == :jsonl do
      emit_jsonl(Map.merge(description, %{"schema_version" => 1, "type" => "profile"}))
    else
      description
      |> ValuePreview.render_with_notice(max_chars: preview_chars(opts))
      |> Map.fetch!(:text)
      |> info()
    end
  end

  defp unsupported_profile_message,
    do: "unsupported session profile; accepted: #{Enum.join(AnalysisProfileRegistry.ids(), ", ")}"

  defp validate_profile_combinations(recipe, opts, arguments, evals, resources, format) do
    cond do
      opts[:manifest] ->
        {:error, :profile_with_manifest}

      opts[:host_config] ->
        {:error, :profile_with_host_config}

      opts[:trace] ->
        {:error, :profile_with_trace}

      resources == [] ->
        {:error, :profile_resources_required}

      format == "jsonl" and jsonl_reachable?(recipe, opts) and evals == [] and arguments == [] ->
        {:error, :jsonl_requires_input}

      opts[:continue_on_error] && length(evals) < 2 ->
        {:error, :continue_requires_repeated_eval}

      true ->
        :ok
    end
  end

  # Ask the registry what this invocation can actually reach rather than
  # reading the profile's static declaration; --private-unattended widens it.
  defp jsonl_reachable?(recipe, opts) do
    unattended = Keyword.get(opts, :private_unattended, false)
    :jsonl in AnalysisProfileRegistry.reachable_frontend(recipe, unattended).output_formats
  end

  defp profile_input_mode(opts, arguments, evals) do
    cond do
      opts[:load] -> :load
      evals != [] -> :eval
      arguments == ["-"] -> :stdin
      arguments != [] -> :script
      true -> :interactive
    end
  end

  defp profile_frontend_error(:profile_with_manifest),
    do: "cannot combine --profile with --manifest"

  defp profile_frontend_error(:profile_with_trace),
    do: "use --session-trace-dir instead of --trace with --profile"

  defp profile_frontend_error(:profile_with_host_config),
    do: "--host-config requires --manifest"

  defp profile_frontend_error(:profile_resources_required),
    do: "--profile requires its declared --resource values"

  defp profile_frontend_error(:jsonl_requires_input),
    do: "--format jsonl requires non-interactive profile input"

  defp profile_frontend_error(:continue_requires_repeated_eval),
    do: "--continue-on-error requires repeated --eval in profile mode"

  defp profile_frontend_error(:unsupported_profile_input),
    do: "selected profile is interactive-only"

  defp profile_frontend_error(:unsupported_profile_output),
    do: "selected profile does not allow this output format"

  defp profile_frontend_error(:unsupported_profile_continuation),
    do: "selected profile does not allow --continue-on-error"

  defp profile_frontend_error(:private_terminal_required),
    do: "selected private analysis profile requires --private-terminal"

  defp profile_frontend_error(:interactive_terminal_required),
    do: "selected private analysis profile requires attached stdin and stdout terminals"

  defp profile_frontend_error(:private_terminal_unsupported),
    do: "--private-terminal is supported only by a private analysis profile"

  defp profile_frontend_error(:private_destination_conflict),
    do: "--private-terminal and --private-unattended are mutually exclusive"

  defp profile_frontend_error(:selected_runs_unsupported),
    do: "--run is supported only with --profile private-run-analysis-v2"

  defp profile_frontend_error(_reason), do: "invalid profile command"

  defp validate_selected_runs(recipe, opts) do
    case Keyword.get_values(opts, :run) do
      [] ->
        :ok

      run_refs when recipe == PtcRunner.Kernel.PrivateRunAnalysisProfile ->
        case SelectedCanonicalSource.validate_run_refs(run_refs) do
          {:ok, _validated} -> :ok
          {:error, _reason} = error -> error
        end

      _run_refs ->
        {:error, :selected_runs_unsupported}
    end
  end

  defp run_profile_session(opts, arguments) do
    case reserve_profile_result(opts) do
      {:ok, nil} ->
        run_profile_session(opts, arguments, nil, nil)

      {:ok, result_handle, result_role} ->
        try do
          run_profile_session(opts, arguments, result_handle, result_role)
        after
          PublicationHandle.discard(result_handle)
        end

      {:error, _reason} ->
        command_error(opts, :cli, "profile result destination unavailable")
    end
  end

  defp run_profile_session(opts, arguments, result_handle, result_role) do
    with {:ok, recipe} <- AnalysisProfileRegistry.fetch(opts[:profile]),
         {:ok, resources} <- profile_resources(opts, recipe),
         {:ok, output_directory, temporary?} <- profile_output_directory(opts) do
      case separate_directories(
             resources,
             output_directory,
             temporary?,
             result_handle,
             result_role
           ) do
        {:ok, output_identity} ->
          start_profile_session(
            opts,
            arguments,
            resources,
            output_directory,
            temporary?,
            output_identity,
            result_handle
          )

        {:error, message, extra} ->
          cleanup_temporary_directory(output_directory, temporary?)
          command_error(opts, :cli, message, extra)
      end
    else
      {:error, category, message} -> command_error(opts, category, message)
    end
  end

  defp reserve_profile_result(opts) do
    case {opts[:output], opts[:private_output]} do
      {nil, nil} ->
        {:ok, nil}

      {path, nil} when is_binary(path) ->
        reserved_result(path, %{id: "output", label: "--output"})

      {nil, path} when is_binary(path) ->
        reserved_result(path, %{id: "private_output", label: "--private-output"})

      _ ->
        {:error, :invalid_destination}
    end
  end

  defp reserved_result(path, role) do
    case PublicationHandle.reserve(path, :result, 0o600) do
      {:ok, handle} -> {:ok, handle, role}
      {:error, _reason} = error -> error
    end
  end

  defp profile_resources(opts, recipe) do
    resources = Keyword.get_values(opts, :resource)

    with {:ok, parsed} <- parse_resources(resources, recipe.resource_names()),
         true <- Map.keys(parsed) |> Enum.sort() == recipe.resource_names(),
         {:ok, expanded} <- expand_resource_directories(parsed) do
      {:ok, expanded}
    else
      {:error, message} -> {:error, :cli, message}
      _ -> {:error, :cli, "#{recipe.id()} requires its declared directory resources"}
    end
  rescue
    _exception -> {:error, :cli, "#{recipe.id()} requires its declared directory resources"}
  end

  defp parse_resources(resources, allowed_names) do
    Enum.reduce_while(resources, {:ok, %{}}, fn resource, {:ok, parsed} ->
      with true <- is_binary(resource) and String.valid?(resource),
           [name, value] <- String.split(resource, "=", parts: 2),
           true <- name =~ ~r/\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/,
           true <- value != "" and String.valid?(value),
           false <- Map.has_key?(parsed, name),
           true <- name in allowed_names do
        {:cont, {:ok, Map.put(parsed, name, value)}}
      else
        true -> {:halt, {:error, "duplicate profile resource"}}
        false -> {:halt, {:error, "invalid or unsupported profile resource"}}
        _ -> {:halt, {:error, "invalid profile resource; expected NAME=VALUE"}}
      end
    end)
  end

  defp expand_resource_directories(resources) do
    Enum.reduce_while(resources, {:ok, %{}}, fn {name, directory}, {:ok, expanded} ->
      case AnalysisDirectory.resolve(directory) do
        {:ok, %{path: resolved}} ->
          {:cont, {:ok, Map.put(expanded, name, resolved)}}

        _ ->
          {:halt, {:error, "profile resources must be existing directories"}}
      end
    end)
  end

  defp profile_output_directory(opts) do
    case opts[:session_trace_dir] do
      nil -> create_temporary_trace_directory(16)
      directory -> existing_output_directory(directory)
    end
  end

  defp existing_output_directory(directory) do
    case AnalysisDirectory.resolve(directory) do
      {:ok, %{path: expanded}} ->
        {:ok, expanded, false}

      {:error, _reason} ->
        {:error, :cli, "--session-trace-dir must be an existing normal directory"}
    end
  rescue
    _exception -> {:error, :cli, "--session-trace-dir must be an existing normal directory"}
  end

  defp create_temporary_trace_directory(0),
    do: {:error, :setup, "could not create a private session trace directory"}

  defp create_temporary_trace_directory(attempts) do
    base = System.tmp_dir!() |> Path.expand()
    name = "ptc-repl-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    directory = Path.join(base, name)

    case File.mkdir(directory) do
      :ok ->
        case File.chmod(directory, 0o700) do
          :ok ->
            {:ok, directory, true}

          {:error, _reason} ->
            _ = File.rmdir(directory)
            {:error, :setup, "could not secure the session trace directory"}
        end

      {:error, :eexist} ->
        create_temporary_trace_directory(attempts - 1)

      {:error, _reason} ->
        {:error, :setup, "could not create a private session trace directory"}
    end
  rescue
    _exception -> {:error, :setup, "could not create a private session trace directory"}
  end

  defp separate_directories(resources, output_directory, temporary?, result_handle, result_role) do
    with {:ok, inputs} <- resource_directories(resources),
         {:ok, {_role, output} = session_trace} <-
           resolve_role_directory(output_directory, session_trace_role(temporary?)),
         {:ok, result_outputs} <- result_output_directories(result_handle, result_role),
         :ok <- DirectorySeparation.verify(inputs ++ [session_trace] ++ result_outputs) do
      {:ok, output.identity}
    else
      {:error, {:unavailable, role}} ->
        {:error, "#{role.label} became unavailable before the analysis session started", %{}}

      {:error, conflict} ->
        {:error, conflict.message,
         %{
           "directory_conflict" => %{
             "left_role" => conflict.left_role,
             "right_role" => conflict.right_role,
             "relation" => conflict.relation
           }
         }}
    end
  end

  defp resource_directories(resources) do
    resources
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {name, directory}, {:ok, resolved} ->
      role = %{id: "resource.#{name}", label: "--resource #{name}"}

      case resolve_role_directory(directory, role) do
        {:ok, labelled} -> {:cont, {:ok, resolved ++ [labelled]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_role_directory(directory, role) do
    case AnalysisDirectory.resolve(directory) do
      {:ok, resolved} -> {:ok, {role, resolved}}
      {:error, _reason} -> {:error, {:unavailable, role}}
    end
  end

  defp session_trace_role(true),
    do: %{id: "session_trace_auto", label: "the auto-created session trace directory"}

  defp session_trace_role(false),
    do: %{id: "session_trace", label: "--session-trace-dir"}

  defp result_output_directories(nil, _role), do: {:ok, []}

  defp result_output_directories(handle, role) do
    case handle |> PublicationHandle.path() |> Path.dirname() |> resolve_role_directory(role) do
      {:ok, labelled} -> {:ok, [labelled]}
      {:error, _reason} = error -> error
    end
  end

  defp start_profile_session(
         opts,
         arguments,
         resources,
         output_directory,
         temporary?,
         output_identity,
         result_handle
       ) do
    builder_options =
      [
        expected_destination_identity: output_identity,
        preview_chars: preview_chars(opts)
      ]
      |> maybe_private_terminal(opts)
      |> maybe_selected_runs(opts)

    case AnalysisSessionBuilder.start(
           opts[:profile],
           resources,
           {:directory, output_directory},
           builder_options
         ) do
      {:ok, session, info} ->
        trace_path = Path.join(output_directory, info.session_id <> ".jsonl")

        try do
          present_profile_started(opts, info)
          state = evaluate_profile_mode(session, opts, arguments)
          finish_profile_session(session, opts, state, trace_path, result_handle)
        rescue
          exception ->
            safe_profile_abort(session, :frontend_exception)
            reraise exception, __STACKTRACE__
        catch
          kind, reason ->
            safe_profile_abort(session, :frontend_exit)
            :erlang.raise(kind, reason, __STACKTRACE__)
        after
          AnalysisSession.stop(session)
        end

      {:error, reason} ->
        cleanup_temporary_directory(output_directory, temporary?)
        command_error(opts, :setup, ProfileDiagnosticCatalog.classify!(reason))
    end
  end

  defp maybe_private_terminal(builder_options, opts) do
    builder_options =
      if Keyword.get(opts, :private_unattended, false),
        do: Keyword.put(builder_options, :private_unattended, true),
        else: builder_options

    if Keyword.get(opts, :private_terminal, false),
      do:
        builder_options
        |> Keyword.put(:private_terminal, true)
        |> Keyword.put(:terminal_attached, Keyword.fetch!(opts, :terminal_attached)),
      else: builder_options
  end

  defp maybe_selected_runs(builder_options, opts) do
    case Keyword.get_values(opts, :run) do
      [] -> builder_options
      run_refs -> Keyword.put(builder_options, :selected_run_refs, run_refs)
    end
  end

  defp evaluate_profile_mode(session, opts, arguments) do
    initial = %{
      next_index: 1,
      failed_indexes: [],
      failure: nil,
      evaluation_diagnostic: nil,
      result: :unavailable
    }

    case maybe_profile_load(session, opts, initial) do
      {:ok, state} -> run_profile_input(session, opts, arguments, state)
      {:halt, state} -> state
    end
  end

  defp maybe_profile_load(session, opts, state) do
    case opts[:load] do
      nil ->
        {:ok, state}

      path ->
        read_profile_load(session, opts, path, state)
    end
  end

  defp read_profile_load(session, opts, path, state) do
    case read_bounded_profile_file(path, opts) do
      {:ok, source} ->
        case evaluate_profile_source(session, opts, source, :load, state) do
          {:ok, next} ->
            if output_format(opts) == :clojure, do: info("Loaded #{path}")
            {:ok, next}

          {_disposition, next} ->
            {:halt, put_failure(next, :setup, evaluation_diagnostic(next))}
        end

      {:error, :source_limit_exceeded} ->
        {:halt,
         put_failure(
           state,
           :setup,
           "profile load exceeds the #{profile_source_bytes(opts)}-byte source limit"
         )}

      {:error, _reason} ->
        {:halt, put_failure(state, :setup, "could not read the profile load file")}
    end
  end

  defp run_profile_input(session, opts, arguments, state) do
    evals = Keyword.get_values(opts, :eval)

    cond do
      evals != [] -> run_profile_sources(session, opts, evals, :eval, state)
      arguments == ["-"] -> read_profile_stdin(session, opts, state)
      arguments != [] -> run_profile_file(session, opts, hd(arguments), state)
      true -> interactive_profile(session, opts, state)
    end
  end

  defp run_profile_sources(session, opts, sources, input_kind, state) do
    Enum.reduce_while(sources, state, fn source, current ->
      case evaluate_profile_source(session, opts, source, input_kind, current) do
        {:ok, next} ->
          {:cont, next}

        {:error, next} ->
          if opts[:continue_on_error],
            do: {:cont, next},
            else: {:halt, put_failure(next, :evaluation, evaluation_diagnostic(next))}

        {:terminal, next} ->
          {:halt, put_failure(next, :lifecycle, evaluation_diagnostic(next))}
      end
    end)
    |> ensure_evaluation_failure()
  end

  defp read_profile_stdin(session, opts, state) do
    case read_bounded_profile_stdin(opts) do
      {:ok, source} ->
        profile_single_source(session, opts, source, :stdin, state)

      {:error, :source_limit_exceeded} ->
        put_failure(
          state,
          :frontend,
          "profile stdin exceeds the #{profile_source_bytes(opts)}-byte source limit"
        )

      {:error, _reason} ->
        put_failure(state, :frontend, "could not read profile stdin")
    end
  end

  defp run_profile_file(session, opts, file, state) do
    case read_bounded_profile_file(file, opts) do
      {:ok, source} ->
        profile_single_source(session, opts, source, :script, state)

      {:error, :source_limit_exceeded} ->
        put_failure(
          state,
          :setup,
          "profile script exceeds the #{profile_source_bytes(opts)}-byte source limit"
        )

      {:error, _reason} ->
        put_failure(state, :setup, "could not read the profile script")
    end
  end

  defp profile_single_source(session, opts, source, input_kind, state) do
    case evaluate_profile_source(session, opts, source, input_kind, state) do
      {:ok, next} -> next
      {:error, next} -> put_failure(next, :evaluation, evaluation_diagnostic(next))
      {:terminal, next} -> put_failure(next, :lifecycle, evaluation_diagnostic(next))
    end
  end

  # The profile reader is bounded per character to enforce the profile source
  # limit, which the interactive line editor cannot drive, so this loop keeps
  # the plain reader and with it `Ctrl+D`.
  defp interactive_profile(session, opts, state) do
    banner =
      "PTC-Lisp REPL [#{opts[:profile]}] (Ctrl+D or :quit to exit; :help for commands)" <>
        terminal_hint(Keyword.fetch!(opts, :terminal_attached))

    info(banner)

    profile_loop(session, opts, state)
  end

  defp profile_loop(session, opts, state) do
    case read_profile_expression("ptc> ", "", opts) do
      :eof ->
        info("\nGoodbye!")
        ensure_evaluation_failure(state)

      {:error, :source_limit_exceeded} ->
        put_failure(
          state,
          :frontend,
          "profile interactive input exceeds the #{profile_source_bytes(opts)}-byte source limit"
        )

      {:error, reason} ->
        put_failure(state, :frontend, "profile interactive input failed: #{inspect(reason)}")

      "" ->
        profile_loop(session, opts, state)

      command when command in [":quit", ":exit"] ->
        info("Goodbye!")
        ensure_evaluation_failure(state)

      ":" <> command ->
        handle_profile_command(String.trim(command), opts[:profile])
        profile_loop(session, opts, state)

      source ->
        case evaluate_profile_source(session, opts, source, :interactive, state) do
          {:ok, next} ->
            profile_loop(session, opts, next)

          {:error, next} ->
            profile_loop(session, opts, next)

          {:terminal, next} ->
            put_failure(next, :lifecycle, evaluation_diagnostic(next))
        end
    end
  end

  defp evaluate_profile_source(session, opts, source, input_kind, state) do
    index = state.next_index

    case AnalysisSession.evaluate(session, source) do
      {:ok, result} ->
        present_profile_result(opts, index, input_kind, result)

        next =
          state
          |> Map.put(:next_index, index + 1)
          |> retain_profile_result(result)

        if result.status == :ok do
          {:ok, next}
        else
          next =
            next
            |> Map.put(:failed_indexes, [index | next.failed_indexes])
            |> retain_evaluation_diagnostic(result)

          case AnalysisSession.info(session) do
            {:ok, %{lifecycle: :open}} -> {:error, next}
            _ -> {:terminal, next}
          end
        end

      {:error, _reason} ->
        {:terminal, %{state | next_index: index + 1}}
    end
  end

  defp ensure_evaluation_failure(%{failure: nil, failed_indexes: [_ | _]} = state),
    do: put_failure(state, :evaluation, evaluation_diagnostic(state))

  defp ensure_evaluation_failure(state), do: state

  defp put_failure(%{failure: nil} = state, category, message),
    do: %{state | failure: {category, message}}

  defp put_failure(state, _category, _message), do: state

  defp retain_evaluation_diagnostic(%{evaluation_diagnostic: nil} = state, result),
    do: %{state | evaluation_diagnostic: classify_evaluation_result(result)}

  defp retain_evaluation_diagnostic(state, _result), do: state

  defp classify_evaluation_result(%{outcome: :result_exceeded}),
    do: ProfileDiagnosticCatalog.classify!(:result_limit_exceeded)

  defp classify_evaluation_result(_result),
    do: ProfileDiagnosticCatalog.classify!(:profile_evaluation_failed)

  defp evaluation_diagnostic(%{evaluation_diagnostic: nil}),
    do: ProfileDiagnosticCatalog.classify!(:profile_evaluation_failed)

  defp evaluation_diagnostic(%{evaluation_diagnostic: diagnostic}), do: diagnostic

  defp retain_profile_result(state, %{status: :ok, value_available?: true, value: value}),
    do: %{state | result: {:ok, value}}

  defp retain_profile_result(state, _result), do: state

  defp finish_profile_session(session, opts, state, trace_path, result_handle) do
    case close_profile_session(session) do
      {:ok, info} ->
        present_profile_closed(opts, info, trace_path)

        case state.failure do
          nil ->
            publish_profile_result(result_handle, state.result)

          {category, %{code: code, message: message}} ->
            command_error(opts, category, code, message, %{
              "evaluation_indexes" => Enum.reverse(state.failed_indexes)
            })

          {category, message} ->
            command_error(opts, category, message, %{
              "evaluation_indexes" => Enum.reverse(state.failed_indexes)
            })
        end

      {:error, reason} ->
        command_error(opts, :persistence, "profile trace persistence failed: #{reason}")
    end
  end

  defp publish_profile_result(nil, _result), do: :ok

  defp publish_profile_result(handle, {:ok, value}) do
    with {:ok, encoded} <- value |> json_projection() |> DeterministicJSON.encode(),
         :ok <- PublicationHandle.write(handle, encoded <> "\n"),
         :ok <- PublicationHandle.sync(handle),
         :ok <- PublicationHandle.publish(handle),
         :ok <- PublicationHandle.release(handle) do
      :ok
    else
      _ -> fail("profile result publication failed")
    end
  end

  defp publish_profile_result(_handle, :unavailable),
    do: fail("profile evaluation produced no publishable value")

  defp close_profile_session(session) do
    case AnalysisSession.close(session) do
      {:ok, _info} = success -> success
      {:error, _first_reason} -> AnalysisSession.close(session)
    end
  end

  defp present_profile_started(opts, info) do
    if output_format(opts) == :jsonl do
      emit_jsonl(%{
        "schema_version" => 1,
        "type" => "session-started",
        "profile_id" => info.profile_id,
        "profile_digest" => info.profile_digest,
        "session_id" => info.session_id,
        "namespaces" => info.namespaces,
        "capture" => Map.new(capture_summary(info.snapshot))
      })
    else
      Enum.each(capture_summary(info.snapshot), &present_capture_summary/1)
    end
  end

  # Run-evidence profiles report trace/inspection captures. Catalog discovery
  # reports its one frozen safe-metadata generation instead.
  defp capture_summary(%{traces: traces, inspection: inspection}),
    do: capture_summary(traces, "traces") ++ capture_summary(inspection, "inspection")

  defp capture_summary(%{
         source: :ptc_run_catalog,
         row_count: row_count,
         excluded_files: excluded_files
       })
       when is_integer(row_count) and is_integer(excluded_files) do
    [
      {"catalog", %{"row_count" => row_count, "excluded_files" => excluded_files}}
    ]
  end

  defp capture_summary(snapshot), do: capture_summary(snapshot, "traces")

  defp capture_summary(%{file_count: file_count, run_count: run_count}, resource)
       when is_integer(file_count) and is_integer(run_count),
       do: [{resource, %{"file_count" => file_count, "run_count" => run_count}}]

  defp capture_summary(_info, _resource), do: []

  defp present_capture_summary({"catalog", counts}) do
    info(
      "Captured catalog: #{pluralize(counts["row_count"], "row")}, " <>
        pluralize(counts["excluded_files"], "excluded file")
    )
  end

  defp present_capture_summary({resource, counts}) do
    info(
      "Captured #{resource}: #{pluralize(counts["file_count"], "file")}, " <>
        pluralize(counts["run_count"], "run")
    )
  end

  defp pluralize(1, noun), do: "1 #{noun}"
  defp pluralize(count, noun), do: "#{count} #{noun}s"

  defp present_profile_result(opts, index, input_kind, result) do
    if output_format(opts) == :jsonl do
      emit_jsonl(%{
        "schema_version" => 1,
        "type" => "evaluation",
        "index" => index,
        "input_kind" => Atom.to_string(input_kind),
        "result" => json_projection(result)
      })
    else
      Enum.each(result.prints, &info/1)
      if is_binary(result.formatted), do: info(result.formatted)
      if result.status == :error, do: error(format_profile_error(result))
    end
  end

  defp present_profile_closed(opts, info, trace_path) do
    if output_format(opts) == :jsonl do
      emit_jsonl(%{
        "schema_version" => 1,
        "type" => "session-closed",
        "status" => "ok",
        "trace_path" => trace_path,
        "session" =>
          info
          |> Map.take([:lifecycle, :evaluation_count, :terminal_reason, :usage, :trace])
          |> json_projection()
      })
    else
      info("Analysis trace: #{trace_path}")
    end
  end

  defp format_profile_error(result) do
    error = result.error || %{}
    kind = Map.get(error, :kind, result.outcome)
    message = Map.get(error, :message) || Map.get(error, :reason) || result.outcome
    "Error (#{kind}): #{message} [continuation #{result.continuation_effect}]"
  end

  defp handle_profile_command("help", profile_id) do
    {:ok, description} = AnalysisProfileRegistry.description(profile_id)
    components = Enum.join(description["components"], ", ")
    namespaces = Enum.map_join(description["namespaces"], ", ", &(&1 <> "."))

    info("""
    Commands:
      :help            Show this help
      :quit            Leave the REPL

    #{introspection_hint()}

    Profile: #{profile_id}; components: #{components}; exported namespaces: #{namespaces}
    Use (tool/runtime-usage {}) to inspect remaining bounded usage.
    """)
  end

  defp handle_profile_command("context", _profile_id),
    do: info(":context is available only in a manifest mission REPL")

  defp handle_profile_command(_command, _profile_id),
    do: info("Unknown command. Available: :help, :quit")

  @spec command_error(keyword(), atom(), map()) :: no_return()
  defp command_error(opts, category, %{code: code, message: message})
       when is_atom(code) and is_binary(message),
       do: command_error(opts, category, code, message)

  @spec command_error(keyword(), atom(), binary()) :: no_return()
  defp command_error(opts, category, message) when is_binary(message),
    do: command_error(opts, category, message, %{})

  @spec command_error(keyword(), atom(), atom(), binary()) :: no_return()
  defp command_error(opts, category, code, message) when is_atom(code) and is_binary(message),
    do: command_error(opts, category, code, message, %{})

  @spec command_error(keyword(), atom(), binary(), map()) :: no_return()
  defp command_error(opts, category, message, extra) when is_binary(message) and is_map(extra) do
    emit_command_error(opts, category, message, extra)
    fail(message)
  end

  @spec command_error(keyword(), atom(), atom(), binary(), map()) :: no_return()
  defp command_error(opts, category, code, message, extra)
       when is_atom(code) and is_binary(message) and is_map(extra) do
    emit_command_error(opts, category, message, Map.put(extra, "code", Atom.to_string(code)))
    fail(code, message)
  end

  defp emit_command_error(opts, category, message, extra) do
    if output_format(opts) == :jsonl do
      emit_jsonl(
        Map.merge(
          %{
            "schema_version" => 1,
            "type" => "command-error",
            "category" => Atom.to_string(category),
            "message" => message
          },
          extra
        )
      )
    end
  end

  defp output_format(opts),
    do: if(Keyword.get(opts, :format) == "jsonl", do: :jsonl, else: :clojure)

  defp emit_jsonl(value) do
    case value |> json_projection() |> DeterministicJSON.encode() do
      {:ok, encoded} -> IO.puts(encoded)
      {:error, _reason} -> fail("ptc repl could not encode JSONL output")
    end
  end

  defp json_projection(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, nested} -> {json_key(key), json_projection(nested)} end)
  end

  defp json_projection(value) when is_list(value), do: Enum.map(value, &json_projection/1)
  defp json_projection(value) when is_boolean(value) or is_nil(value), do: value
  defp json_projection(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp json_projection(value), do: value

  defp json_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.trim_trailing("?")
  defp json_key(key) when is_binary(key), do: key

  defp safe_profile_abort(session, reason) do
    case AnalysisSession.info(session) do
      {:ok, %{lifecycle: lifecycle}}
      when lifecycle in [:closed, :persistence_failed, :backend_failed] ->
        :ok

      _ ->
        _ = AnalysisSession.abort(session, reason)
        :ok
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp cleanup_temporary_directory(directory, true) do
    _ = File.rmdir(directory)
    :ok
  end

  defp cleanup_temporary_directory(_directory, false), do: :ok

  defp read_bounded_profile_file(path, opts) do
    max_bytes = profile_source_bytes(opts)

    path
    |> File.open([:read, :binary], &IO.binread(&1, max_bytes + 1))
    |> bounded_profile_source(max_bytes)
  end

  defp read_bounded_profile_stdin(opts) do
    max_bytes = profile_source_bytes(opts)

    :stdio
    |> IO.read(max_bytes + 1)
    |> bounded_profile_source(max_bytes)
  end

  defp bounded_profile_source(:eof, _max_bytes), do: {:ok, ""}

  defp bounded_profile_source({:ok, source}, max_bytes),
    do: bounded_profile_source(source, max_bytes)

  defp bounded_profile_source(source, max_bytes)
       when is_binary(source) and byte_size(source) <= max_bytes,
       do: {:ok, source}

  defp bounded_profile_source(source, _max_bytes) when is_binary(source),
    do: {:error, :source_limit_exceeded}

  defp bounded_profile_source({:error, reason}, _max_bytes), do: {:error, reason}

  defp profile_source_bytes(opts) do
    {:ok, recipe} = AnalysisProfileRegistry.fetch(opts[:profile])
    recipe.limits().subordinate_source_bytes
  end

  defp read_profile_expression(prompt, buffer, opts) do
    remaining = profile_source_bytes(opts) - byte_size(buffer)

    case read_bounded_line(prompt, max(remaining, 0)) do
      {:ok, line} ->
        source = buffer <> line

        if balanced?(source),
          do: String.trim(source),
          else: read_profile_expression("...> ", source, opts)

      :eof ->
        :eof

      {:error, _reason} = error ->
        error
    end
  end

  defp read_bounded_line(prompt, max_bytes),
    do: read_bounded_line(prompt, max_bytes, [], 0)

  defp read_bounded_line(prompt, max_bytes, characters, bytes) do
    case IO.getn(prompt, 1) do
      :eof when characters == [] ->
        :eof

      :eof ->
        {:ok, characters |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, reason} ->
        {:error, reason}

      character when is_binary(character) ->
        next_bytes = bytes + byte_size(character)

        cond do
          next_bytes > max_bytes ->
            {:error, :source_limit_exceeded}

          String.ends_with?(character, "\n") ->
            {:ok, [character | characters] |> Enum.reverse() |> IO.iodata_to_binary()}

          true ->
            read_bounded_line("", max_bytes, [character | characters], next_bytes)
        end
    end
  end

  defp run_inspect_only_session(opts, arguments) do
    case InspectOnlyRepl.open(opts[:manifest],
           mission: opts[:mission],
           interactive_loop: interactive_input?(opts, arguments),
           installed_limits: opts[:installed_limits]
         ) do
      {:ok, session} ->
        run_workflow_session(session, opts, arguments)

      {:error, %{code: :unknown_mission, declared: declared}} ->
        fail("unknown mission #{inspect(opts[:mission])}; declared: #{Enum.join(declared, ", ")}")

      {:error, %{code: code, diagnostic: diagnostic}} ->
        case CommandDiagnosticRenderer.render(diagnostic) do
          {:ok, rendered} -> fail(rendered)
          {:error, :invalid_command_diagnostic} -> fail(manifest_repl_error(code))
        end

      {:error, %{code: code}} ->
        fail(manifest_repl_error(code))

      {:error, reason} ->
        fail("ptc repl setup failed: #{inspect(reason)}")
    end
  end

  defp run_direct_session(opts, arguments) do
    constructor =
      if interactive_input?(opts, arguments),
        do: &ReplSession.new_interactive/1,
        else: &ReplSession.new/1

    case constructor.(trace_path: opts[:trace]) do
      {:ok, session} -> run_workflow_session(session, opts, arguments)
      {:error, reason} -> fail("ptc repl setup failed: #{inspect(reason)}")
    end
  end

  defp run_manifest_session(opts, arguments) do
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
      run_workflow_session(session, opts, arguments)
    else
      {:error, %{code: :unknown_mission, declared: declared}} ->
        fail("unknown mission #{inspect(opts[:mission])}; declared: #{Enum.join(declared, ", ")}")

      {:error, %{code: code, diagnostic: diagnostic}} ->
        case CommandDiagnosticRenderer.render(diagnostic) do
          {:ok, rendered} -> fail(rendered)
          {:error, :invalid_command_diagnostic} -> fail(manifest_repl_error(code))
        end

      {:error, %{code: code}} ->
        fail(manifest_repl_error(code))

      {:error, reason} ->
        fail("ptc repl setup failed: #{inspect(reason)}")
    end
  end

  defp run_workflow_session(session, opts, arguments) do
    render = render_context(opts)
    outcome = evaluate_mode(session, opts, arguments, render)
    finish(outcome, render)
  rescue
    exception ->
      abort_session(session, :frontend_exception)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      abort_session(session, :frontend_exit)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

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

  defp manifest_repl_error(:environment_file_invalid_utf8),
    do: "the named environment file is not valid UTF-8"

  defp manifest_repl_error(code) when is_atom(code),
    do: "ptc repl setup failed: #{code}"

  defp evaluate_mode(session, opts, arguments, render) do
    with {:ok, session} <- maybe_load(session, opts[:load], render) do
      cond do
        opts[:eval] ->
          run_sources(session, Keyword.get_values(opts, :eval), render)

        arguments == ["-"] ->
          read_stdin(session, render)

        arguments != [] ->
          run_file(session, hd(arguments), render)

        true ->
          interactive(
            session,
            session_mode(opts),
            render,
            Keyword.fetch!(opts, :terminal_attached)
          )
      end
    end
  end

  # `--mission` is manifest-only, so a direct session must not be told to pass
  # it. The frontend is the only layer that knows which one this is: a direct
  # session still carries one synthetic mission environment, indistinguishable
  # in the session read model from a manifest that declares exactly one.
  defp render_context(opts),
    do: %{preview_chars: preview_chars(opts), mission_selectable?: opts[:manifest] != nil}

  defp preview_chars(opts), do: Keyword.get(opts, :preview_chars, 2_048)

  defp maybe_load(session, nil, _render), do: {:ok, session}

  defp maybe_load(session, path, render) do
    with {:ok, source} <- File.read(path),
         {:ok, _step, session} <- evaluate(session, source, :noninteractive, render) do
      info("Loaded #{path}")
      {:ok, session}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason, session}
      {:error, step, session} -> {:error, step, session}
    end
  end

  defp run_sources(session, sources, render) do
    Enum.reduce_while(sources, {:ok, session}, fn source, {:ok, current} ->
      case evaluate(current, source, :noninteractive, render) do
        {:ok, _step, next} -> {:cont, {:ok, next}}
        {:error, step, next} -> {:halt, {:error, step, next}}
      end
    end)
  end

  defp read_stdin(session, render) do
    case IO.read(:stdio, :eof) do
      source when is_binary(source) -> evaluate_outcome(session, source, render)
      :eof -> {:ok, session}
      {:error, reason} -> {:error, reason, session}
    end
  end

  defp run_file(session, path, render) do
    case File.read(path) do
      {:ok, source} -> evaluate_outcome(session, source, render)
      {:error, reason} -> {:error, reason, session}
    end
  end

  defp evaluate_outcome(session, source, render) do
    case evaluate(session, source, :noninteractive, render) do
      {:ok, _step, session} -> {:ok, session}
      {:error, step, session} -> {:error, step, session}
    end
  end

  # A manifest session can carry a private event policy, so it line-edits
  # without persisting anything to disk. See `PtcRunner.ReplLineEditor`.
  defp session_mode(opts), do: if(opts[:manifest], do: :manifest, else: :direct)

  # The line editor owns the banner: under the interactive reader it is the
  # reader's own slogan, which keeps it ahead of the first prompt instead of
  # racing it.
  defp interactive(session, mode, render, terminal_attached?) do
    banner = session_banner(ReplSession.mode_info(session), terminal_attached?)
    LineEditor.run(mode, banner, fn -> loop(session, render) end)
  end

  defp session_banner(%{kind: :mission} = mode, terminal_attached?) do
    inspect_only_prefix(mode) <>
      mission_banner(mode) <>
      terminal_hint(terminal_attached?)
  end

  defp session_banner(%{inspect_only: true} = mode, terminal_attached?) do
    inspect_only_prefix(mode) <>
      LineEditor.banner() <>
      terminal_hint(terminal_attached?)
  end

  defp session_banner(_mode, terminal_attached?),
    do: LineEditor.banner() <> terminal_hint(terminal_attached?)

  defp mission_banner(%{
         mission: name,
         component_ids: component_ids,
         direct_provider_aliases: provider_aliases,
         inventory_hash: hash
       }) do
    components = Enum.join(component_ids, ", ")
    providers = if provider_aliases == [], do: "none", else: Enum.join(provider_aliases, ", ")

    "PTC-Lisp mission REPL [#{name}; components: #{components}; providers: #{providers}; " <>
      "inventory #{String.slice(hash, 0, 12)}; no workflow/model access] " <>
      "(:quit to exit; :help for commands)"
  end

  defp inspect_only_prefix(%{inspect_only: true}),
    do: InspectOnlyRepl.startup_notice() <> "\n"

  defp inspect_only_prefix(_mode), do: ""

  defp terminal_hint(true), do: "\n" <> introspection_hint()
  defp terminal_hint(false), do: ""

  defp introspection_hint do
    ~S|Explore functions with (apropos "term") and (doc "name"); inspect attached APIs with (dir), (export-meta "ns/name"), and (source ns/name).|
  end

  defp loop(session, render) do
    input = read_expression("ptc> ", "")

    case ReplSession.terminal_error(session) do
      {:error, step} -> {:error, step, session}
      :none -> handle_loop_input(input, session, render)
    end
  end

  defp handle_loop_input(input, session, render) do
    case input do
      :eof ->
        info("\nGoodbye!")
        {:ok, session}

      "" ->
        loop(session, render)

      command when command in [":quit", ":exit"] ->
        info("Goodbye!")
        {:ok, session}

      ":" <> command ->
        handle_command(String.trim(command), session)
        loop(session, render)

      source ->
        case evaluate(session, source, :interactive, render) do
          {:ok, _step, next} ->
            loop(next, render)

          {:error, step, next} ->
            if ReplSession.terminal?(next),
              do: {:error, step, next},
              else: loop(next, render)
        end
    end
  end

  # An interrupted read answers an error tuple rather than a line and is not
  # end of input: the prompt returns. Any other read error means the stream is
  # no longer usable, and looping on it would spin.
  defp read_expression(prompt, buffer) do
    case IO.gets(prompt) do
      :eof ->
        :eof

      {:error, :interrupted} ->
        read_expression(prompt, buffer)

      {:error, _reason} ->
        :eof

      line ->
        source = buffer <> line
        if balanced?(source), do: String.trim(source), else: read_expression("...> ", source)
    end
  end

  defp balanced?(source) do
    source
    |> String.graphemes()
    |> Enum.reduce_while({0, false, false}, fn
      _char, {depth, _quoted?, _escaped?} when depth < 0 -> {:halt, {-1, false, false}}
      "\\", {depth, true, false} -> {:cont, {depth, true, true}}
      _char, {depth, true, true} -> {:cont, {depth, true, false}}
      "\"", {depth, quoted?, false} -> {:cont, {depth, not quoted?, false}}
      "(", {depth, false, false} -> {:cont, {depth + 1, false, false}}
      ")", {depth, false, false} -> {:cont, {depth - 1, false, false}}
      _char, state -> {:cont, state}
    end)
    |> case do
      {0, false, false} -> true
      _state -> false
    end
  end

  defp evaluate(session, source, mode, render) do
    case ReplSession.eval(session, source) do
      {:ok, step, next} ->
        print_step(step, render)
        {:ok, step, next}

      {:error, step, next} ->
        message = format_error(step, next, render)

        cond do
          mode == :interactive and not ReplSession.terminal?(next) -> info(message)
          mode == :noninteractive -> error(message)
          true -> :ok
        end

        {:error, step, next}
    end
  end

  defp print_step(step, %{preview_chars: preview_chars}) do
    Enum.each(step.prints, &info/1)

    preview =
      ValuePreview.render_with_notice(LispResult.unwrap_return(step.return),
        max_chars: preview_chars,
        max_bytes: preview_chars * 4
      )

    info(preview.text)
  end

  defp format_error(
         %{fail: %{reason: reason, message: message, details: details}} = step,
         session,
         render
       )
       when is_atom(reason) and is_binary(message) do
    case EvaluatorError.public_evidence(reason, details || %{}) do
      {:ok, %{kind: kind, message: public_message}} ->
        "Error (#{kind}): " <> mission_hint(step, session, render) <> public_message

      :error ->
        body = String.replace_prefix(message, "#{reason}: ", "")
        "Error (#{reason}): " <> mission_hint(step, session, render) <> body
    end
  end

  defp format_error(%{fail: %{reason: reason, message: message}} = step, session, render),
    do: "Error (#{reason}): " <> mission_hint(step, session, render) <> to_string(message)

  # The analyzer answers an unknown namespace with the language's own list,
  # thirty-odd entries that name no mission, because a workflow session cannot
  # reach one. A `data/<name>` form answers from the language instead: an
  # ungranted name is the strict missing-grant error and a granted one called
  # as a function is `not_callable`, because `data/` is a language namespace
  # the workflow environment does carry. Which switch would add mission names
  # is a REPL fact rather than a language fact, so it is said here instead of
  # in the shared diagnostic -- whose exact text is also reverse-parsed by
  # `NamespaceDiagnostic.rejected_namespace/1`.
  #
  # It leads, because the enumeration that follows is long enough to be
  # truncated by the one-shot renderer and is the least actionable part of the
  # answer.
  defp mission_hint(%{fail: %{message: message}}, session, %{mission_selectable?: true})
       when is_binary(message) do
    with true <- workflow_mission_hint?(message),
         %{kind: :workflow, declared_missions: [_ | _] = declared} <-
           ReplSession.mode_info(session) do
      "this session evaluates the workflow environment and carries no mission " <>
        "namespaces; pass --mission NAME to evaluate one instead " <>
        "(declared: #{Enum.join(declared, ", ")}). "
    else
      _other -> ""
    end
  end

  defp mission_hint(_step, _session, _render), do: ""

  defp workflow_mission_hint?(message) do
    NamespaceDiagnostic.unknown_namespace?(message) or
      NamespaceDiagnostic.data_not_callable?(message) or
      NamespaceDiagnostic.missing_data_grant?(message)
  end

  defp finish({:ok, session}, _render) do
    stop_session(session)
  end

  defp finish({:error, %{} = step, session}, render) do
    message = format_error(step, session, render)
    stop_session(session)
    fail(message)
  end

  defp finish({:error, reason, session}, _render) do
    stop_session(session)
    fail("ptc repl failed: #{inspect(reason)}")
  end

  defp stop_session(session) do
    case ReplSession.close(session) do
      {:ok, _events} ->
        :ok

      {:error, :provider_cleanup_failed, _events} ->
        fail("ptc repl cleanup failed: :provider_cleanup_failed")

      {:error, :provider_cleanup_failed} ->
        fail("ptc repl cleanup failed: :provider_cleanup_failed")

      {:error, :trace_persistence_failed, _events} ->
        fail("ptc repl trace failed: :trace_persistence_failed")

      {:error, reason} ->
        fail("ptc repl cleanup failed: #{inspect(reason)}")
    end
  end

  defp abort_session(session, reason) do
    case ReplSession.abort(session, reason) do
      {:error, :trace_persistence_failed, _events} ->
        IO.puts(:stderr, "ptc repl trace failed: :trace_persistence_failed")

      {:error, :provider_cleanup_failed, _events} ->
        IO.puts(:stderr, "ptc repl cleanup failed: :provider_cleanup_failed")

      {:error, :provider_cleanup_failed} ->
        IO.puts(:stderr, "ptc repl cleanup failed: :provider_cleanup_failed")

      _result ->
        :ok
    end

    :ok
  end

  defp handle_command("help", session) do
    context =
      case ReplSession.mode_info(session) do
        %{kind: :mission} -> "  :context         Show the frozen mission model context\n"
        _mode -> ""
      end

    info(
      "Commands:\n" <>
        context <>
        "  :help            Show this help\n" <>
        "  :quit            Leave the REPL\n\n" <>
        introspection_hint() <>
        "\n\n" <>
        "Successful results and definitions persist. *1, *2, and *3 read recent results."
    )
  end

  defp handle_command("context", session) do
    case ReplSession.mission_context(session) do
      {:ok, context} ->
        info("Mission: #{context.mission}")
        info("Model context SHA-256: #{context.model_context_hash}")
        info(context.model_context)

      {:error, :not_mission_session} ->
        info(":context is available only in a mission REPL")

      {:error, reason} ->
        info("Unable to read mission context: #{reason}")
    end
  end

  defp handle_command(_command, session) do
    commands =
      case ReplSession.mode_info(session) do
        %{kind: :mission} -> ":context, :help, :quit"
        _mode -> ":help, :quit"
      end

    info("Unknown command. Available: #{commands}")
  end

  defp info(message), do: IO.puts(message)
  defp error(message), do: IO.puts(:stderr, message)
  defp fail(message), do: raise(ReplError, message: message)
  defp fail(code, message), do: raise(ReplError, code: code, message: message)
end
