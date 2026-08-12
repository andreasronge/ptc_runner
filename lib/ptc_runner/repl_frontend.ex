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
      ptc repl --manifest ptc.json --trace trace.jsonl
      ptc repl --profile run-analysis-v1 --resource traces=tmp/traces
      ptc repl --profile private-run-analysis-v1 \
        --resource traces=tmp/traces \
        --resource inspection=tmp/inspection \
        --private-terminal
      ptc repl --profile private-run-analysis-v1 \
        --resource traces=tmp/traces \
        --resource inspection=tmp/inspection \
        --private-unattended --format jsonl -e '(analysis/runs {})'
      ptc repl --describe-profile run-analysis-v1

  Options:

    * `-e, --eval` — evaluate an expression; repeat to preserve definitions and
      `*1`/`*2`/`*3` history;
    * `-l, --load` — evaluate a setup file before expressions or interaction;
    * `-m, --manifest` — reuse a strict Kernel manifest's workflow bundle,
      capabilities, limits, input, labels, and event policy;
    * `--host-config` — manifest-only trusted provider installation document;
    * `-t, --trace` — append this session's canonical events to a JSONL file;
    * `--profile` — select a code-owned mission session profile;
    * `--resource NAME=VALUE` — supply a required profile resource; repeatable;
    * `--session-trace-dir` — existing output directory for a profile session's
      separate canonical trace;
    * `--output` / `--private-output` — atomically publish the value of exactly
      one non-interactive public/private profile evaluation;
    * `--private-terminal` — explicitly authorize an attached terminal as the
      private output sink required by `private-run-analysis-v1`;
    * `--private-unattended` — explicitly authorize this command's own streams
      as that sink instead, admitting `-e`/`--load`/script/stdin and
      `--format jsonl`. Mutually exclusive with `--private-terminal`;
    * `--format clojure|jsonl` — choose human output or non-interactive
      profile-mode JSON Lines;
    * `--continue-on-error` — evaluate later repeated `--eval` forms after a
      recoverable profile evaluation error, then exit unsuccessfully;
    * `--describe-profile` — print a safe static profile contract;
    * `-h, --help` — print this help without loading files or providers.

  A positional file runs as one script. `-` reads one script from standard
  input. With no script or `--eval`, the task starts an interactive multi-line
  REPL. Ctrl+D exits.

  Direct and manifest sessions evaluate the workflow environment. Profile mode
  evaluates one serialized mission continuation over the exact resources
  declared by its closed profile. Its analysis trace is atomically published
  outside captured private resources; without `--session-trace-dir`, the task
  creates and reports a private temporary output directory.

  JSONL mode is non-interactive and conditionally emits schema-version-1
  `session-started`, `evaluation`, and successfully persisted `session-closed`
  records for lifecycle stages that are reached. An unsuccessful command ends
  with `command-error`; validation failures can therefore emit that record
  alone. Evaluation records contain the existing bounded public mission result
  projection and never add a raw source field. A failing command raises
  a closed frontend error; this shared module never halts the VM.
  """

  alias PtcRunner.Kernel.AnalysisDirectory
  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.AnalysisSession
  alias PtcRunner.Kernel.AnalysisSessionBuilder
  alias PtcRunner.Kernel.AnalysisTerminal
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.ManifestRepl
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Registry
  alias PtcRunner.ReplError

  @spec run(CommandArguments.t(), CommandRuntime.t()) :: :ok | {:error, binary()}
  def run(
        %CommandArguments{command: :repl, application: script, ordered_options: opts},
        %CommandRuntime{} = runtime
      ) do
    arguments = if is_binary(script), do: [script], else: []

    case validate_command(opts, arguments, []) do
      {:ok, :describe} ->
        describe_profile(opts)

      {:ok, :profile} ->
        run_profile_session(opts, arguments)

      {:ok, :manifest} ->
        run_manifest_session(Keyword.put(opts, :command_runtime, runtime), arguments)

      {:ok, :direct} ->
        run_direct_session(opts, arguments)

      {:error, message} ->
        command_error(opts, :cli, message)
    end

    :ok
  rescue
    error in ReplError -> {:error, error.message}
  end

  defp validate_command(opts, arguments, invalid) do
    format = Keyword.get(opts, :format, "clojure")
    evals = Keyword.get_values(opts, :eval)
    resources = Keyword.get_values(opts, :resource)

    with :ok <- validate_common_command(arguments, invalid, evals, format) do
      select_command(opts, arguments, evals, resources, format)
    end
  end

  defp validate_common_command(arguments, invalid, evals, format) do
    cond do
      invalid != [] ->
        {:error, "invalid ptc repl options: #{inspect(invalid)}"}

      length(arguments) > 1 ->
        {:error, "usage: ptc repl [OPTIONS] [SCRIPT|-]"}

      evals != [] and arguments != [] ->
        {:error, "cannot combine --eval with a script or stdin"}

      format not in ["clojure", "jsonl"] ->
        {:error, "invalid ptc repl format: #{inspect(format)}"}

      true ->
        :ok
    end
  end

  defp select_command(opts, arguments, evals, resources, format) do
    cond do
      opts[:describe_profile] ->
        validate_description(opts, arguments)

      opts[:profile] ->
        validate_profile_command(opts, arguments, evals, resources, format)

      opts[:manifest] ->
        validate_manifest_command(opts, resources, format)

      opts[:host_config] ->
        {:error, "--host-config requires --manifest"}

      resources != [] or not is_nil(opts[:session_trace_dir]) or
        Keyword.has_key?(opts, :continue_on_error) or
        Keyword.has_key?(opts, :private_terminal) or
          Keyword.has_key?(opts, :private_unattended) ->
        {:error, "profile options require --profile"}

      format == "jsonl" ->
        {:error, "--format jsonl requires --profile or --describe-profile"}

      true ->
        {:ok, :direct}
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

  defp validate_profile_command(opts, arguments, evals, resources, format) do
    with {:ok, recipe} <- AnalysisProfileRegistry.fetch(opts[:profile]),
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
             terminal_attached: AnalysisTerminal.attached?()
           }) do
      {:ok, :profile}
    else
      {:error, :unsupported_analysis_profile} -> {:error, unsupported_profile_message()}
      {:error, reason} when is_atom(reason) -> {:error, profile_frontend_error(reason)}
    end
  end

  defp describe_profile(opts) do
    {:ok, description} = AnalysisProfileRegistry.description(opts[:describe_profile])

    if output_format(opts) == :jsonl do
      emit_jsonl(Map.merge(description, %{"schema_version" => 1, "type" => "profile"}))
    else
      {formatted, _truncated?} = Format.to_clojure(description)
      info(formatted)
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
    do: "private-run-analysis-v1 requires --private-terminal"

  defp profile_frontend_error(:interactive_terminal_required),
    do: "private-run-analysis-v1 requires attached stdin and stdout terminals"

  defp profile_frontend_error(:private_terminal_unsupported),
    do: "--private-terminal is supported only by a private analysis profile"

  defp profile_frontend_error(:private_destination_conflict),
    do: "--private-terminal and --private-unattended are mutually exclusive"

  defp profile_frontend_error(_reason), do: "invalid profile command"

  defp run_profile_session(opts, arguments) do
    case reserve_profile_result(opts) do
      {:ok, result_handle} ->
        try do
          run_profile_session(opts, arguments, result_handle)
        after
          if result_handle, do: PublicationHandle.discard(result_handle)
        end

      {:error, _reason} ->
        command_error(opts, :cli, "profile result destination unavailable")
    end
  end

  defp run_profile_session(opts, arguments, result_handle) do
    with {:ok, recipe} <- AnalysisProfileRegistry.fetch(opts[:profile]),
         {:ok, resources} <- profile_resources(opts, recipe),
         {:ok, output_directory, temporary?} <- profile_output_directory(opts) do
      case separate_directories(Map.values(resources), output_directory, result_handle) do
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

        {:error, message} ->
          cleanup_temporary_directory(output_directory, temporary?)
          command_error(opts, :cli, message)
      end
    else
      {:error, category, message} -> command_error(opts, category, message)
    end
  end

  defp reserve_profile_result(opts) do
    case {opts[:output], opts[:private_output]} do
      {nil, nil} -> {:ok, nil}
      {path, nil} when is_binary(path) -> PublicationHandle.reserve(path, :result, 0o600)
      {nil, path} when is_binary(path) -> PublicationHandle.reserve(path, :result, 0o600)
      _ -> {:error, :invalid_destination}
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

  defp separate_directories(input_directories, output_directory, result_handle) do
    with {:ok, output} <- AnalysisDirectory.resolve(output_directory),
         {:ok, inputs} <- AnalysisDirectory.resolve_all(input_directories),
         {:ok, result_outputs} <- result_output_directories(result_handle),
         true <- AnalysisDirectory.pairwise_separate?([output | result_outputs ++ inputs]) do
      {:ok, output.identity}
    else
      _ -> {:error, "input and session trace directories must be physically separate"}
    end
  end

  defp result_output_directories(nil), do: {:ok, []}

  defp result_output_directories(handle) do
    case handle |> PublicationHandle.path() |> Path.dirname() |> AnalysisDirectory.resolve() do
      {:ok, directory} -> {:ok, [directory]}
      {:error, _reason} -> {:error, :invalid_result_directory}
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
      [expected_destination_identity: output_identity]
      |> maybe_private_terminal(opts)

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
        command_error(opts, :setup, profile_setup_error(reason))
    end
  end

  defp profile_setup_error(
         {:source_retained_limit_exceeded,
          %{source: source, measured_bytes: measured_bytes, limit_bytes: limit_bytes}}
       )
       when source in [
              :ptc_trace_snapshot,
              :ptc_private_trace_snapshot,
              :ptc_inspection_snapshot
            ] and
              is_integer(measured_bytes) and is_integer(limit_bytes) do
    "ptc repl profile setup failed: #{source} retains #{measured_bytes} bytes " <>
      "(limit: #{limit_bytes} bytes)"
  end

  defp profile_setup_error(:empty_traces_resource),
    do: empty_resource_error("traces", "*.jsonl trace files")

  defp profile_setup_error(:empty_inspection_resource),
    do: empty_resource_error("inspection", "*.inspection.jsonl records")

  defp profile_setup_error(
         {:unsupported_inspection_schema_version,
          %{artifact_version: artifact_version, supported_version: supported_version}}
       )
       when is_integer(artifact_version) and is_integer(supported_version) do
    "ptc repl profile setup failed: an inspection artifact declares schema version " <>
      "#{artifact_version}; this build supports version #{supported_version}. " <>
      "Use a matching PtcRunner build or regenerate the artifact."
  end

  defp profile_setup_error(reason) when is_atom(reason),
    do: "ptc repl profile setup failed: #{reason}"

  defp profile_setup_error(_reason), do: "ptc repl profile setup failed"

  defp empty_resource_error(resource, artifacts) do
    "ptc repl profile setup failed: the #{resource} resource directory contains no " <>
      "#{artifacts} at its own level; artifacts in subdirectories are not captured"
  end

  defp maybe_private_terminal(builder_options, opts) do
    builder_options =
      if Keyword.get(opts, :private_unattended, false),
        do: Keyword.put(builder_options, :private_unattended, true),
        else: builder_options

    if Keyword.get(opts, :private_terminal, false),
      do: Keyword.put(builder_options, :private_terminal, true),
      else: builder_options
  end

  defp evaluate_profile_mode(session, opts, arguments) do
    initial = %{next_index: 1, failed_indexes: [], failure: nil, result: :unavailable}

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
            {:halt, put_failure(next, :setup, "profile load evaluation failed")}
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
            else: {:halt, put_failure(next, :evaluation, "profile evaluation failed")}

        {:terminal, next} ->
          {:halt, put_failure(next, :lifecycle, "profile session became terminal")}
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
      {:error, next} -> put_failure(next, :evaluation, "profile evaluation failed")
      {:terminal, next} -> put_failure(next, :lifecycle, "profile session became terminal")
    end
  end

  defp interactive_profile(session, opts, state) do
    info("PTC-Lisp REPL [#{opts[:profile]}] (Ctrl+D to exit; :help for commands)\n")

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

      "" ->
        profile_loop(session, opts, state)

      ":" <> command ->
        handle_profile_command(String.trim(command), opts[:profile])
        profile_loop(session, opts, state)

      source ->
        case evaluate_profile_source(session, opts, source, :interactive, state) do
          {:ok, next} -> profile_loop(session, opts, next)
          {:error, next} -> profile_loop(session, opts, next)
          {:terminal, next} -> put_failure(next, :lifecycle, "profile session became terminal")
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
          next = %{next | failed_indexes: [index | next.failed_indexes]}

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
    do: put_failure(state, :evaluation, "one or more profile evaluations failed")

  defp ensure_evaluation_failure(state), do: state

  defp put_failure(%{failure: nil} = state, category, message),
    do: %{state | failure: {category, message}}

  defp put_failure(state, _category, _message), do: state

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
      Enum.each(capture_summary(info.snapshot), fn {resource, counts} ->
        info(
          "Captured #{resource}: #{pluralize(counts["file_count"], "file")}, " <>
            pluralize(counts["run_count"], "run")
        )
      end)
    end
  end

  # The log profile reports its one trace capture directly; the private profile
  # reports one entry per captured resource.
  defp capture_summary(%{traces: traces, inspection: inspection}),
    do: capture_summary(traces, "traces") ++ capture_summary(inspection, "inspection")

  defp capture_summary(snapshot), do: capture_summary(snapshot, "traces")

  defp capture_summary(%{file_count: file_count, run_count: run_count}, resource)
       when is_integer(file_count) and is_integer(run_count),
       do: [{resource, %{"file_count" => file_count, "run_count" => run_count}}]

  defp capture_summary(_info, _resource), do: []

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
      :doc <name>      Show core function documentation
      :find <pattern>  Search core functions
      :help            Show this help

    Profile: #{profile_id}; components: #{components}; exported namespaces: #{namespaces}
    Use (tool/runtime-usage {}) to inspect remaining bounded usage.
    """)
  end

  defp handle_profile_command(command, _profile_id), do: handle_command(command, nil)

  @spec command_error(keyword(), atom(), binary()) :: no_return()
  defp command_error(opts, category, message), do: command_error(opts, category, message, %{})

  @spec command_error(keyword(), atom(), binary(), map()) :: no_return()
  defp command_error(opts, category, message, extra) do
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

    fail(message)
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

  defp run_direct_session(opts, arguments) do
    case ReplSession.new(trace_path: opts[:trace]) do
      {:ok, session} -> run_workflow_session(session, opts, arguments)
      {:error, reason} -> fail("ptc repl setup failed: #{inspect(reason)}")
    end
  end

  defp run_manifest_session(opts, arguments) do
    with {:ok, runtime} <- manifest_runtime(opts),
         {:ok, session} <-
           ManifestRepl.open(opts[:manifest], opts[:host_config],
             runtime: runtime,
             trace_path: opts[:trace],
             private_terminal: Keyword.get(opts, :private_terminal, false),
             terminal_attached: AnalysisTerminal.attached?(),
             input_mode: manifest_input_mode(opts, arguments)
           ) do
      run_workflow_session(session, opts, arguments)
    else
      {:error, %{code: code}} -> fail(manifest_repl_error(code))
      {:error, reason} -> fail("ptc repl setup failed: #{inspect(reason)}")
    end
  end

  defp run_workflow_session(session, opts, arguments) do
    outcome = evaluate_mode(session, opts, arguments)
    finish(outcome)
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

  defp manifest_repl_error(code) when is_atom(code),
    do: "ptc repl setup failed: #{code}"

  defp evaluate_mode(session, opts, arguments) do
    with {:ok, session} <- maybe_load(session, opts[:load]) do
      cond do
        opts[:eval] -> run_sources(session, Keyword.get_values(opts, :eval))
        arguments == ["-"] -> read_stdin(session)
        arguments != [] -> run_file(session, hd(arguments))
        true -> interactive(session)
      end
    end
  end

  defp maybe_load(session, nil), do: {:ok, session}

  defp maybe_load(session, path) do
    with {:ok, source} <- File.read(path),
         {:ok, _step, session} <- evaluate(session, source, :noninteractive) do
      info("Loaded #{path}")
      {:ok, session}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason, session}
      {:error, step, session} -> {:error, step, session}
    end
  end

  defp run_sources(session, sources) do
    Enum.reduce_while(sources, {:ok, session}, fn source, {:ok, current} ->
      case evaluate(current, source, :noninteractive) do
        {:ok, _step, next} -> {:cont, {:ok, next}}
        {:error, step, next} -> {:halt, {:error, step, next}}
      end
    end)
  end

  defp read_stdin(session) do
    case IO.read(:stdio, :eof) do
      source when is_binary(source) -> evaluate_outcome(session, source)
      :eof -> {:ok, session}
      {:error, reason} -> {:error, reason, session}
    end
  end

  defp run_file(session, path) do
    case File.read(path) do
      {:ok, source} -> evaluate_outcome(session, source)
      {:error, reason} -> {:error, reason, session}
    end
  end

  defp evaluate_outcome(session, source) do
    case evaluate(session, source, :noninteractive) do
      {:ok, _step, session} -> {:ok, session}
      {:error, step, session} -> {:error, step, session}
    end
  end

  defp interactive(session) do
    info("PTC-Lisp REPL (Ctrl+D to exit; :help for commands)\n")
    loop(session)
  end

  defp loop(session) do
    case read_expression("ptc> ", "") do
      :eof ->
        info("\nGoodbye!")
        {:ok, session}

      "" ->
        loop(session)

      ":" <> command ->
        handle_command(String.trim(command), session)
        loop(session)

      source ->
        case evaluate(session, source, :interactive) do
          {:ok, _step, next} -> loop(next)
          {:error, _step, next} -> loop(next)
        end
    end
  end

  defp read_expression(prompt, buffer) do
    case IO.gets(prompt) do
      :eof ->
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

  defp evaluate(session, source, mode) do
    case ReplSession.eval(session, source) do
      {:ok, step, next} ->
        print_step(step)
        {:ok, step, next}

      {:error, step, next} ->
        message = format_error(step)
        if mode == :interactive, do: info(message), else: error(message)
        {:error, step, next}
    end
  end

  defp print_step(step) do
    Enum.each(step.prints, &info/1)
    {formatted, _truncated?} = Format.to_clojure(step.return)
    info(formatted)
  end

  defp format_error(%{fail: %{reason: reason, message: message}}),
    do: "Error (#{reason}): #{message}"

  defp finish({:ok, session}) do
    stop_session(session)
  end

  defp finish({:error, %{} = step, session}) do
    stop_session(session)
    fail(format_error(step))
  end

  defp finish({:error, reason, session}) do
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

  defp handle_command("help", _session) do
    info("""
    Commands:
      :doc <name>      Show core function documentation
      :find <pattern>  Search core functions
      :help            Show this help

    Successful results and definitions persist. *1, *2, and *3 read recent results.
    """)
  end

  defp handle_command("doc " <> name, _session) do
    case Registry.doc(String.trim(name)) do
      nil -> info("No documentation found for: #{String.trim(name)}")
      entry -> info(format_registry_doc(entry))
    end
  end

  defp handle_command("find " <> pattern, _session) do
    pattern
    |> String.trim()
    |> Registry.find_doc()
    |> Enum.each(fn entry ->
      info("#{entry.name} — #{Enum.join(entry.signatures, " | ")}")
    end)
  end

  defp handle_command(_command, _session),
    do: info("Unknown command. Available: :doc <name>, :find <pattern>, :help")

  defp format_registry_doc(entry) do
    details =
      [entry.description, entry.notes, entry.divergences]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n  ")

    Enum.join(entry.signatures, "\n") <> "\n  " <> details
  end

  defp info(message), do: IO.puts(message)
  defp error(message), do: IO.puts(:stderr, message)
  defp fail(message), do: raise(ReplError, message: message)
end
