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
      for direct, manifest, and profile human output (64–65536; default 2048).
      `--describe-profile` prints its contract whole and does not accept it;
    * `--continue-on-error` — with `--profile`, evaluate later repeated `--eval`
      forms after a recoverable profile evaluation error, then exit
      unsuccessfully. It is accepted in no other mode;
    * `--describe-profile` — print a safe static profile contract whole, in
      Clojure syntax or, with `--format jsonl`, as one JSON record;
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
  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.AnalysisTerminal
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandDiagnosticRenderer
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.InspectOnlyRepl
  alias PtcRunner.Kernel.ProjectContext
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.SelectedCanonicalSource
  alias PtcRunner.Lisp.EvaluatorError
  alias PtcRunner.Lisp.Format, as: LispFormat
  alias PtcRunner.Lisp.NamespaceDiagnostic
  alias PtcRunner.Lisp.Result, as: LispResult
  alias PtcRunner.Lisp.ValuePreview
  alias PtcRunner.ProfileDiagnosticCatalog
  alias PtcRunner.ReplError
  alias PtcRunner.ReplLineEditor, as: LineEditor
  alias PtcRunner.ReplProfileRunner
  alias PtcRunner.ReplSessionRunner

  import PtcRunner.ReplSupport

  # Catalogued kinds whose fixed public sentence drops detail a local session
  # needs: the offending type, and the denied capability name with the granted
  # inventory beside it.

  @detailed_repl_kinds [:type_error, :unknown_tool]

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
          ReplProfileRunner.run(
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

              ReplSessionRunner.inspect_only(opts, arguments, &run_workflow_session/3)

            {:error, %CommandDiagnostic{} = diagnostic} ->
              fail_command_diagnostic(diagnostic)
          end

        {:ok, :manifest} ->
          opts =
            opts
            |> Keyword.put(:command_runtime, runtime)
            |> Keyword.put(:terminal_attached, terminal_attached?)

          ReplSessionRunner.manifest(opts, arguments, &run_workflow_session/3)

        {:ok, :direct} ->
          ReplSessionRunner.direct(
            Keyword.put(opts, :terminal_attached, terminal_attached?),
            arguments,
            &run_workflow_session/3
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
           }),
         :ok <- validate_profile_evaluation_count(opts, evals) do
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

  defp validate_profile_evaluation_count(opts, evals) do
    if opts[:continue_on_error] && length(evals) < 2 do
      {:error, :continue_requires_repeated_eval}
    else
      :ok
    end
  end

  defp describe_profile(opts) do
    {:ok, description} = AnalysisProfileRegistry.description(opts[:describe_profile])

    if output_format(opts) == :jsonl do
      emit_jsonl(Map.merge(description, %{"schema_version" => 1, "type" => "profile"}))
    else
      # The contract is a small, fixed, code-owned document with no caller value
      # in it, so it is rendered whole. Passing it through the structural preview
      # abbreviated the field names the command exists to publish, and
      # --preview-chars is not admitted beside --describe-profile.
      description |> LispFormat.to_clojure() |> elem(0) |> info()
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

      true ->
        :ok
    end
  end

  # Ask the registry what this invocation can actually reach rather than
  # reading the profile's static declaration; --private-unattended widens it.
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

  # Normal REPL diagnostics keep the evaluator's own text for kinds whose
  # public evidence is a fixed sentence: the denied name and the granted
  # inventory are what make a local session actionable, and neither reaches
  # the command envelope.
  defp format_error(
         %{fail: %{reason: reason, message: message}} = step,
         session,
         render
       )
       when reason in @detailed_repl_kinds and is_binary(message) do
    body = String.replace_prefix(message, "#{reason}: ", "")
    "Error (#{reason}): " <> mission_hint(step, session, render) <> body
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
end
