defmodule PtcRunner.ReplProfileRunner do
  @moduledoc false
  alias PtcRunner.Kernel.AnalysisDirectory
  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.AnalysisSession
  alias PtcRunner.Kernel.AnalysisSessionBuilder
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.DirectorySeparation
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.ProfileDiagnosticCatalog

  import PtcRunner.ReplSupport

  def run(opts, arguments) do
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

  defp create_temporary_trace_directory(attempts) do
    case PrivateDirectory.create_temp("ptc-repl-", attempts) do
      {:ok, directory} -> {:ok, directory, true}
      {:error, _reason} -> {:error, :setup, "could not create a private session trace directory"}
    end
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
      result: :unavailable,
      jsonl_hint?: jsonl_hint_available?(opts, arguments)
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
        present_profile_result(opts, index, input_kind, result, state.jsonl_hint?)

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

  defp present_profile_result(opts, index, input_kind, result, jsonl_hint?) do
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
      present_unabbreviated_hint(jsonl_hint?, result)
      if result.status == :error, do: error(format_profile_error(result))
    end
  end

  # JSON Lines needs a profile that reaches the format and one non-interactive
  # input, so this is a property of the whole invocation rather than of the
  # source that produced any one record: a --load form in a session that also
  # carries -e can reach it.
  defp jsonl_hint_available?(opts, arguments) do
    (Keyword.get_values(opts, :eval) != [] or arguments != []) and
      jsonl_reachable_for?(opts)
  end

  defp jsonl_reachable_for?(opts) do
    case AnalysisProfileRegistry.fetch(opts[:profile]) do
      {:ok, recipe} -> jsonl_reachable?(recipe, opts)
      _error -> false
    end
  end

  # The preview is bounded by design, so a reader who needs the whole value
  # reaches for --preview-chars and finds it does not restore what the ceiling
  # dropped. The same evaluation already carries an unabbreviated `result.value`
  # in JSON Lines mode; name it only when adding --format jsonl to this exact
  # invocation would be accepted and this value has a projection at all.
  defp present_unabbreviated_hint(jsonl_hint?, result) do
    if jsonl_hint? and Map.get(result, :formatted_truncated?, false) and
         Map.get(result, :value_available?, false) do
      info("preview truncated; --format jsonl publishes the unabbreviated result.value")
    end

    :ok
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
end
