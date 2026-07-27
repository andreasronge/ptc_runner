defmodule Mix.Tasks.Ptc.Repl do
  @shortdoc "Bounded direct or profile-backed PTC-Lisp REPL"
  @moduledoc """
  Starts a direct workflow PTC-Lisp REPL or a fixed code-owned analysis
  profile.

      mix ptc.repl
      mix ptc.repl -e "(+ 1 2)" -e "(+ *1 3)"
      mix ptc.repl -l setup.clj
      mix ptc.repl script.clj
      mix ptc.repl -
      mix ptc.repl --manifest ptc.json
      mix ptc.repl --manifest ptc.json --trace trace.jsonl
      mix ptc.repl --profile log-analysis-v1 --resource traces=tmp/traces
      mix ptc.repl --profile inspection-analysis-v1 \
        --resource traces=tmp/traces \
        --resource inspection=tmp/inspection \
        --private-terminal
      mix ptc.repl --describe-profile log-analysis-v1

  Options:

    * `-e, --eval` — evaluate an expression; repeat to preserve definitions and
      `*1`/`*2`/`*3` history;
    * `-l, --load` — evaluate a setup file before expressions or interaction;
    * `-m, --manifest` — reuse a strict Kernel manifest's workflow bundle,
      capabilities, limits, input, labels, and event policy;
    * `-t, --trace` — append this session's canonical events to a JSONL file;
    * `--profile` — select a code-owned mission session profile;
    * `--resource NAME=VALUE` — supply a required profile resource; repeatable;
    * `--session-trace-dir` — existing output directory for a profile session's
      separate canonical trace;
    * `--private-terminal` — explicitly authorize an attached terminal as the
      private output sink required by `inspection-analysis-v1`;
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
  `Mix.Error`; the task never halts the VM directly.
  """

  use Mix.Task

  alias PtcRunner.Kernel.AnalysisDirectory
  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.AnalysisSession
  alias PtcRunner.Kernel.AnalysisSessionBuilder
  alias PtcRunner.Kernel.AnalysisTerminal
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Registry

  @switches [
    eval: :keep,
    load: :string,
    manifest: :string,
    trace: :string,
    profile: :string,
    resource: :keep,
    session_trace_dir: :string,
    format: :string,
    continue_on_error: :boolean,
    private_terminal: :boolean,
    describe_profile: :string,
    help: :boolean
  ]
  @aliases [e: :eval, l: :load, m: :manifest, t: :trace, h: :help]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, arguments, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      case validate_command(opts, arguments, invalid) do
        {:ok, :describe} -> describe_profile(opts)
        {:ok, :profile} -> run_profile_session(opts, arguments)
        {:ok, :direct} -> run_session(opts, arguments)
        {:error, message} -> command_error(opts, :cli, message)
      end
    end
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
        {:error, "invalid ptc.repl options: #{inspect(invalid)}"}

      length(arguments) > 1 ->
        {:error, "usage: mix ptc.repl [OPTIONS] [SCRIPT|-]"}

      evals != [] and arguments != [] ->
        {:error, "cannot combine --eval with a script or stdin"}

      format not in ["clojure", "jsonl"] ->
        {:error, "invalid ptc.repl format: #{inspect(format)}"}

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

      opts[:manifest] && (resources != [] or not is_nil(opts[:session_trace_dir])) ->
        {:error, "profile resources require --profile"}

      resources != [] or not is_nil(opts[:session_trace_dir]) or
        Keyword.has_key?(opts, :continue_on_error) or
          Keyword.has_key?(opts, :private_terminal) ->
        {:error, "profile options require --profile"}

      format == "jsonl" ->
        {:error, "--format jsonl requires --profile or --describe-profile"}

      true ->
        {:ok, :direct}
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
          {:error, _reason} -> {:error, "unsupported session profile"}
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
             terminal_attached: AnalysisTerminal.attached?()
           }) do
      {:ok, :profile}
    else
      {:error, :unsupported_analysis_profile} -> {:error, "unsupported session profile"}
      {:error, reason} when is_atom(reason) -> {:error, profile_frontend_error(reason)}
    end
  end

  defp describe_profile(opts) do
    {:ok, description} = AnalysisProfileRegistry.description(opts[:describe_profile])

    if output_format(opts) == :jsonl do
      emit_jsonl(Map.merge(description, %{"schema_version" => 1, "type" => "profile"}))
    else
      {formatted, _truncated?} = Format.to_clojure(description)
      Mix.shell().info(formatted)
    end
  end

  defp validate_profile_combinations(recipe, opts, arguments, evals, resources, format) do
    cond do
      opts[:manifest] ->
        {:error, :profile_with_manifest}

      opts[:trace] ->
        {:error, :profile_with_trace}

      resources == [] ->
        {:error, :profile_resources_required}

      format == "jsonl" and :jsonl in recipe.frontend().output_formats and evals == [] and
          arguments == [] ->
        {:error, :jsonl_requires_input}

      opts[:continue_on_error] && length(evals) < 2 ->
        {:error, :continue_requires_repeated_eval}

      true ->
        :ok
    end
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
    do: "inspection-analysis-v1 requires --private-terminal"

  defp profile_frontend_error(:interactive_terminal_required),
    do: "inspection-analysis-v1 requires attached stdin and stdout terminals"

  defp profile_frontend_error(:private_terminal_unsupported),
    do: "--private-terminal is supported only by a private analysis profile"

  defp profile_frontend_error(_reason), do: "invalid profile command"

  defp run_profile_session(opts, arguments) do
    with {:ok, recipe} <- AnalysisProfileRegistry.fetch(opts[:profile]),
         {:ok, resources} <- profile_resources(opts, recipe),
         {:ok, output_directory, temporary?} <- profile_output_directory(opts) do
      case separate_directories(Map.values(resources), output_directory) do
        {:ok, output_identity} ->
          start_profile_session(
            opts,
            arguments,
            resources,
            output_directory,
            temporary?,
            output_identity
          )

        {:error, message} ->
          cleanup_temporary_directory(output_directory, temporary?)
          command_error(opts, :cli, message)
      end
    else
      {:error, category, message} -> command_error(opts, category, message)
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

  defp separate_directories(input_directories, output_directory) do
    with {:ok, output} <- AnalysisDirectory.resolve(output_directory),
         {:ok, inputs} <- resolve_directories(input_directories),
         true <- AnalysisDirectory.pairwise_separate?([output | inputs]) do
      {:ok, output.identity}
    else
      _ -> {:error, "input and session trace directories must be physically separate"}
    end
  end

  defp resolve_directories(directories) do
    Enum.reduce_while(directories, {:ok, []}, fn directory, {:ok, resolved} ->
      case AnalysisDirectory.resolve(directory) do
        {:ok, value} -> {:cont, {:ok, [value | resolved]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp start_profile_session(
         opts,
         arguments,
         resources,
         output_directory,
         temporary?,
         output_identity
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
          finish_profile_session(session, opts, state, trace_path)
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
       when source in [:ptc_trace_snapshot, :ptc_inspection_snapshot] and
              is_integer(measured_bytes) and is_integer(limit_bytes) do
    "ptc.repl profile setup failed: #{source} retains #{measured_bytes} bytes " <>
      "(limit: #{limit_bytes} bytes)"
  end

  defp profile_setup_error(reason) when is_atom(reason),
    do: "ptc.repl profile setup failed: #{reason}"

  defp profile_setup_error(_reason), do: "ptc.repl profile setup failed"

  defp maybe_private_terminal(builder_options, opts) do
    if Keyword.get(opts, :private_terminal, false),
      do: Keyword.put(builder_options, :private_terminal, true),
      else: builder_options
  end

  defp evaluate_profile_mode(session, opts, arguments) do
    initial = %{next_index: 1, failed_indexes: [], failure: nil}

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
            if output_format(opts) == :clojure, do: Mix.shell().info("Loaded #{path}")
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
    Mix.shell().info("PTC-Lisp REPL [#{opts[:profile]}] (Ctrl+D to exit; :help for commands)\n")

    profile_loop(session, opts, state)
  end

  defp profile_loop(session, opts, state) do
    case read_profile_expression("ptc> ", "", opts) do
      :eof ->
        Mix.shell().info("\nGoodbye!")
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
        next = %{state | next_index: index + 1}

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

  defp finish_profile_session(session, opts, state, trace_path) do
    case close_profile_session(session) do
      {:ok, info} ->
        present_profile_closed(opts, info, trace_path)

        case state.failure do
          nil ->
            :ok

          {category, message} ->
            command_error(opts, category, message, %{
              "evaluation_indexes" => Enum.reverse(state.failed_indexes)
            })
        end

      {:error, reason} ->
        command_error(opts, :persistence, "profile trace persistence failed: #{reason}")
    end
  end

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
        "namespaces" => info.namespaces
      })
    end
  end

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
      Enum.each(result.prints, fn print -> Mix.shell().info(print) end)
      if is_binary(result.formatted), do: Mix.shell().info(result.formatted)
      if result.status == :error, do: Mix.shell().error(format_profile_error(result))
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
      Mix.shell().info("Analysis trace: #{trace_path}")
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

    Mix.shell().info("""
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

    Mix.raise(message)
  end

  defp output_format(opts),
    do: if(Keyword.get(opts, :format) == "jsonl", do: :jsonl, else: :clojure)

  defp emit_jsonl(value) do
    case value |> json_projection() |> DeterministicJSON.encode() do
      {:ok, encoded} -> IO.puts(encoded)
      {:error, _reason} -> Mix.raise("ptc.repl could not encode JSONL output")
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

  defp run_session(opts, arguments) do
    with {:ok, config} <- load_config(opts[:manifest]),
         {:ok, session} <- ReplSession.new(config: config) do
      try do
        outcome = evaluate_mode(session, opts, arguments)
        finish(outcome, opts[:trace])
      rescue
        exception ->
          abort_and_persist(session, :frontend_exception, opts[:trace])
          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          abort_and_persist(session, :frontend_exit, opts[:trace])
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      {:error, reason} -> Mix.raise("ptc.repl setup failed: #{inspect(reason)}")
    end
  end

  defp load_config(nil), do: {:ok, nil}

  defp load_config(path) do
    with {:ok, registry} <- ProviderRegistry.new(),
         {:ok, built} <- RunBuilder.load_and_build(path, registry),
         do: {:ok, built.config}
  end

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
      Mix.shell().info("Loaded #{path}")
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
    Mix.shell().info("PTC-Lisp REPL (Ctrl+D to exit; :help for commands)\n")
    loop(session)
  end

  defp loop(session) do
    case read_expression("ptc> ", "") do
      :eof ->
        Mix.shell().info("\nGoodbye!")
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
        if mode == :interactive, do: Mix.shell().info(message), else: Mix.shell().error(message)
        {:error, step, next}
    end
  end

  defp print_step(step) do
    Enum.each(step.prints, fn line -> Mix.shell().info(line) end)
    {formatted, _truncated?} = Format.to_clojure(step.return)
    Mix.shell().info(formatted)
  end

  defp format_error(%{fail: %{reason: reason, message: message}}),
    do: "Error (#{reason}): #{message}"

  defp finish({:ok, session}, trace_path) do
    persist_and_stop(session, trace_path)
  end

  defp finish({:error, %{} = step, session}, trace_path) do
    persist_and_stop(session, trace_path)
    Mix.raise(format_error(step))
  end

  defp finish({:error, reason, session}, trace_path) do
    persist_and_stop(session, trace_path)
    Mix.raise("ptc.repl failed: #{inspect(reason)}")
  end

  defp persist_and_stop(session, trace_path) do
    private? = ReplSession.event_policy(session) == :private

    case persist_terminal_result(ReplSession.close(session), trace_path, private?) do
      :ok ->
        :ok

      {:error, :cleanup, reason} ->
        Mix.raise("ptc.repl cleanup failed: #{inspect(reason)}")

      {:error, :terminal, reason} ->
        Mix.raise("ptc.repl trace failed: #{inspect(reason)}")
    end
  end

  defp abort_and_persist(session, reason, trace_path) do
    private? = ReplSession.event_policy(session) == :private
    _ = persist_abort_result(ReplSession.abort(session, reason), trace_path, private?)
    :ok
  end

  defp persist_abort_result({:ok, events}, trace_path, private?),
    do: persist_trace(trace_path, events, private?)

  defp persist_abort_result(
         {:error, :provider_cleanup_failed, events},
         trace_path,
         private?
       ),
       do: persist_trace(trace_path, events, private?)

  defp persist_abort_result(_result, _trace_path, _private?), do: :ok

  @doc false
  def persist_terminal_result({:ok, events}, trace_path, private?) do
    persist_trace!(trace_path, events, private?)
  end

  def persist_terminal_result(
        {:error, reason, events},
        trace_path,
        private?
      ) do
    persist_trace!(trace_path, events, private?)
    {:error, :cleanup, reason}
  end

  def persist_terminal_result(
        {:error, :provider_cleanup_failed},
        _trace_path,
        _private?
      ),
      do: {:error, :cleanup, :provider_cleanup_failed}

  def persist_terminal_result({:error, reason}, _trace_path, _private?),
    do: {:error, :terminal, reason}

  defp persist_trace!(trace_path, events, private?) do
    case persist_trace(trace_path, events, private?) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("ptc.repl trace failed: #{inspect(reason)}")
    end
  end

  defp persist_trace(nil, _events, _private?), do: :ok

  defp persist_trace(path, events, private?) do
    TraceLog.append_jsonl(path, events, private: private?)
  end

  defp handle_command("help", _session) do
    Mix.shell().info("""
    Commands:
      :doc <name>      Show core function documentation
      :find <pattern>  Search core functions
      :help            Show this help

    Successful results and definitions persist. *1, *2, and *3 read recent results.
    """)
  end

  defp handle_command("doc " <> name, _session) do
    case Registry.doc(String.trim(name)) do
      nil -> Mix.shell().info("No documentation found for: #{String.trim(name)}")
      entry -> Mix.shell().info(Enum.join(entry.signatures, "\n") <> "\n  " <> entry.description)
    end
  end

  defp handle_command("find " <> pattern, _session) do
    pattern
    |> String.trim()
    |> Registry.find_doc()
    |> Enum.each(fn entry ->
      Mix.shell().info("#{entry.name} — #{Enum.join(entry.signatures, " | ")}")
    end)
  end

  defp handle_command(_command, _session),
    do: Mix.shell().info("Unknown command. Available: :doc <name>, :find <pattern>, :help")
end
