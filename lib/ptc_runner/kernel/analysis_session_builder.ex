defmodule PtcRunner.Kernel.AnalysisSessionBuilder do
  @moduledoc """
  Host boundary for closed local analysis profiles.

  The builder resolves a profile ID through the closed registry, captures only
  its declared directory resources, creates fresh bounded owners, and starts
  one attested `PtcRunner.Kernel.AnalysisSession`. No caller can supply a
  profile module, component, capability set, mission data, label, limit, or
  sink policy.

  `inspection-analysis-v1` is admitted only with `private_terminal: true` on
  attached stdin and stdout. That check and physical separation of its trace,
  inspection, and analysis-trace directories happen before either source is
  captured.
  """

  alias PtcRunner.Kernel.AnalysisAssembly
  alias PtcRunner.Kernel.AnalysisDirectory
  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.AnalysisSession
  alias PtcRunner.Kernel.AnalysisTerminal
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.SessionTrace

  @type resources :: %{required(binary()) => binary()}
  @type destination :: {:directory, binary()}

  @common_options [
    :persistence_fault_hook,
    :capture_hook,
    :listing_hook,
    :construction_hook,
    :evaluation_hook,
    :builder_fault_hook,
    :resource_cleanup_hook,
    :expected_destination_identity
  ]
  @inspection_options [:inspection_capture_hook, :inspection_listing_hook, :private_terminal]

  @doc """
  Starts one fixed analysis profile over immutable source captures.

  The destination directory receives one atomically published
  `<analysis-id>.jsonl` trace on close. The Viewer may place a normal log
  profile's source and destination together. The private inspection profile
  always requires all three physical directory lineages to be disjoint,
  including through symlinks and ancestor aliases.
  """
  @spec start(binary(), resources(), destination()) ::
          {:ok, AnalysisSession.t(), map()} | {:error, atom()}
  def start(profile_id, resources, destination),
    do: start(profile_id, resources, destination, [])

  @doc false
  def start(profile_id, resources, {:directory, trace_directory}, opts)
      when is_binary(profile_id) and is_map(resources) and is_binary(trace_directory) and
             is_list(opts) do
    with {:ok, recipe} <- AnalysisProfileRegistry.fetch(profile_id),
         :ok <- validate_options(recipe, opts),
         :ok <- authorize_private_profile(recipe, opts),
         {:ok, expanded_resources} <- normalize_resources(recipe, resources),
         {:ok, expanded_trace_directory, destination_identity} <-
           normalize_destination(trace_directory, opts, recipe),
         :ok <-
           validate_profile_separation(
             recipe,
             expanded_resources,
             expanded_trace_directory
           ),
         {:ok, analysis_resources} <- recipe.capture(expanded_resources, opts) do
      build_owned_resources(
        recipe,
        analysis_resources,
        expanded_trace_directory,
        destination_identity,
        opts
      )
    else
      {:error, :unsupported_analysis_profile} = error -> error
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  rescue
    _exception ->
      profile_error(profile_id, :invalid_source_error, :invalid_analysis_source)
  end

  def start(profile_id, _resources, _destination, _opts),
    do: profile_error(profile_id, :invalid_source_error, :invalid_analysis_source)

  defp validate_options(recipe, opts) do
    allowed =
      if recipe.frontend().private_terminal == :required,
        do: @common_options ++ @inspection_options,
        else: @common_options

    if Keyword.keys(opts) -- allowed == [] and valid_builder_hooks?(opts) and
         valid_capture_hooks?(opts) and valid_private_terminal?(opts) do
      :ok
    else
      {:error, recipe.invalid_source_error()}
    end
  end

  defp valid_builder_hooks?(opts) do
    valid_optional_hook?(Keyword.get(opts, :construction_hook), 2) and
      valid_optional_hook?(Keyword.get(opts, :evaluation_hook), 1) and
      valid_optional_hook?(Keyword.get(opts, :builder_fault_hook), 2) and
      valid_optional_hook?(Keyword.get(opts, :resource_cleanup_hook), 0)
  end

  defp valid_capture_hooks?(opts) do
    valid_optional_hook?(Keyword.get(opts, :capture_hook), 0) and
      valid_optional_hook?(Keyword.get(opts, :listing_hook), 0) and
      valid_optional_hook?(Keyword.get(opts, :inspection_capture_hook), 0) and
      valid_optional_hook?(Keyword.get(opts, :inspection_listing_hook), 0)
  end

  defp valid_private_terminal?(opts),
    do: Keyword.get(opts, :private_terminal, false) in [true, false]

  defp valid_optional_hook?(nil, _arity), do: true
  defp valid_optional_hook?(hook, arity), do: is_function(hook, arity)

  defp authorize_private_profile(recipe, opts) do
    case recipe.frontend().private_terminal do
      :required ->
        cond do
          Keyword.get(opts, :private_terminal, false) != true ->
            {:error, :private_terminal_required}

          not AnalysisTerminal.attached?() ->
            {:error, :interactive_terminal_required}

          true ->
            :ok
        end

      :forbidden ->
        if Keyword.get(opts, :private_terminal, false),
          do: {:error, :private_terminal_unsupported},
          else: :ok
    end
  end

  defp normalize_resources(recipe, resources) do
    expected = recipe.resource_names()

    with true <- Map.keys(resources) |> Enum.sort() == expected,
         true <- Enum.all?(resources, fn {name, path} -> valid_resource?(name, path) end) do
      Enum.reduce_while(resources, {:ok, %{}}, fn {name, path}, {:ok, expanded} ->
        case AnalysisDirectory.resolve(path) do
          {:ok, %{path: resolved}} ->
            {:cont, {:ok, Map.put(expanded, name, resolved)}}

          _ ->
            {:halt, {:error, recipe.invalid_source_error()}}
        end
      end)
    else
      false -> {:error, recipe.invalid_source_error()}
    end
  end

  defp valid_resource?(name, path) do
    is_binary(name) and is_binary(path) and String.valid?(path)
  end

  defp normalize_destination(directory, opts, recipe) do
    with {:ok, %{path: expanded, identity: identity}} <-
           AnalysisDirectory.resolve(directory),
         true <-
           identity == Keyword.get(opts, :expected_destination_identity, identity) do
      {:ok, expanded, identity}
    else
      _ -> {:error, recipe.invalid_source_error()}
    end
  end

  defp validate_profile_separation(recipe, resources, destination) do
    if recipe.frontend().private_terminal == :required do
      directories = Map.values(resources) ++ [destination]

      with {:ok, resolved} <- resolve_directories(directories),
           true <- AnalysisDirectory.pairwise_separate?(resolved) do
        :ok
      else
        _ -> {:error, recipe.invalid_source_error()}
      end
    else
      :ok
    end
  end

  defp resolve_directories(directories) do
    Enum.reduce_while(directories, {:ok, []}, fn directory, {:ok, acc} ->
      case AnalysisDirectory.resolve(directory) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp build_owned_resources(recipe, resources, directory, destination_identity, opts) do
    result =
      try do
        with :ok <-
               builder_fault(
                 recipe,
                 Keyword.get(opts, :builder_fault_hook),
                 :after_snapshot,
                 hook_resources(resources)
               ) do
          build(recipe, resources, directory, destination_identity, opts)
        end
      rescue
        _exception -> {:error, recipe.session_failed_error()}
      catch
        _kind, _reason -> {:error, recipe.session_failed_error()}
      end

    case result do
      {:ok, _session, _info} = success ->
        success

      {:error, reason} ->
        AnalysisResources.stop(resources)
        {:error, normalize_error(reason, recipe)}
    end
  end

  defp build(recipe, resources, trace_directory, destination_identity, opts) do
    limits = recipe.limits()
    run_id = recipe.run_id_prefix() <> random_id()
    destination = Path.join(trace_directory, run_id <> ".jsonl")
    terminal_reserve = EventSink.terminal_reserve(:normal, limits)

    case RunState.start_with_event_sink(
           limits,
           [
             run_id: run_id,
             trace_id: run_id,
             fail_closed: true,
             terminal_reserve: terminal_reserve
           ],
           owner: self()
         ) do
      {:ok, run_state, sink} ->
        start_session(
          recipe,
          resources,
          %{
            run_state: run_state,
            sink: sink,
            limits: limits,
            destination: destination,
            destination_identity: destination_identity,
            run_id: run_id
          },
          opts
        )

      {:error, reason} ->
        {:error, normalize_error(reason, recipe)}
    end
  end

  defp start_session(
         recipe,
         resources,
         %{
           run_state: run_state,
           sink: sink,
           limits: limits,
           destination: destination,
           destination_identity: destination_identity,
           run_id: run_id
         },
         opts
       ) do
    case SessionTrace.start(limits, destination, run_id,
           owner: self(),
           persistence_fault_hook: Keyword.get(opts, :persistence_fault_hook),
           resource_cleanup_hook: Keyword.get(opts, :resource_cleanup_hook),
           destination_directory_identity: destination_identity,
           run_state: run_state,
           event_sink: sink
         ) do
      {:ok, session_trace} ->
        finish_session_trace_start(
          recipe,
          resources,
          session_trace,
          run_state,
          sink,
          opts
        )

      {:error, reason} ->
        cleanup_run_state(run_state)
        AnalysisResources.stop(resources)
        {:error, normalize_error(reason, recipe)}
    end
  end

  defp finish_session_trace_start(recipe, resources, session_trace, run_state, sink, opts) do
    hook_resources =
      hook_resources(resources)
      |> Map.merge(%{
        session_trace: session_trace,
        run_state: run_state,
        event_sink: sink
      })

    result =
      try do
        with :ok <-
               builder_fault(
                 recipe,
                 Keyword.get(opts, :builder_fault_hook),
                 :before_run_state_transfer,
                 hook_resources
               ),
             :ok <- RunState.transfer_owner(run_state, session_trace.pid),
             :ok <-
               builder_fault(
                 recipe,
                 Keyword.get(opts, :builder_fault_hook),
                 :after_session_trace,
                 hook_resources
               ) do
          build_session(recipe, resources, session_trace, run_state, sink, opts)
        end
      rescue
        _exception -> {:error, recipe.session_failed_error()}
      catch
        _kind, _reason -> {:error, recipe.session_failed_error()}
      end

    case result do
      {:ok, _session, _info} = success ->
        success

      {:error, reason} ->
        SessionTrace.stop(session_trace)
        cleanup_run_state(run_state)
        AnalysisResources.stop(resources)
        {:error, normalize_error(reason, recipe)}
    end
  end

  defp build_session(recipe, resources, session_trace, run_state, sink, opts) do
    with {:ok, ^sink} <- SessionTrace.sink(session_trace),
         {:ok, %{config: config, profile: profile}} <- recipe.assemble(resources, sink),
         assembly =
           AnalysisAssembly.seal(config, profile, resources, session_trace, run_state),
         {:ok, session} <-
           AnalysisSession.start(assembly,
             evaluation_hook: Keyword.get(opts, :evaluation_hook),
             initialization_hook: Keyword.get(opts, :builder_fault_hook)
           ) do
      finish_session_start(
        recipe,
        session,
        resources,
        session_trace,
        run_state,
        sink,
        opts
      )
    end
  end

  defp finish_session_start(
         recipe,
         session,
         resources,
         session_trace,
         run_state,
         sink,
         opts
       ) do
    hook_resources =
      hook_resources(resources)
      |> Map.merge(%{
        session: session,
        session_trace: session_trace,
        run_state: run_state,
        event_sink: sink
      })

    result =
      try do
        with :ok <-
               construction_hook(
                 recipe,
                 Keyword.get(opts, :construction_hook),
                 hook_resources
               ),
             :ok <- AnalysisResources.transfer_owner(resources, session.pid),
             {:ok, info} <- AnalysisSession.info(session),
             :ok <-
               builder_fault(
                 recipe,
                 Keyword.get(opts, :builder_fault_hook),
                 :before_builder_release,
                 hook_resources
               ),
             :ok <- SessionTrace.complete_construction(session_trace) do
          {:ok, session, info}
        end
      rescue
        _exception -> {:error, recipe.session_failed_error()}
      catch
        _kind, _reason -> {:error, recipe.session_failed_error()}
      end

    case result do
      {:ok, _session, _info} = success ->
        success

      {:error, _reason} = error ->
        cancel_construction(session_trace)
        AnalysisSession.stop(session)
        AnalysisResources.stop(resources)
        error
    end
  end

  defp hook_resources(resources) do
    %{
      resources: resources,
      snapshot: AnalysisResources.handle(resources, :traces),
      inspection_snapshot: AnalysisResources.handle(resources, :inspection)
    }
  end

  defp cancel_construction(session_trace) do
    SessionTrace.cancel_construction(session_trace)
  catch
    :exit, _reason -> :ok
  end

  defp cleanup_run_state(run_state) do
    RunState.close(run_state)
    RunState.stop(run_state)
  catch
    :exit, _reason -> :ok
  end

  defp construction_hook(_recipe, nil, _resources), do: :ok

  defp construction_hook(recipe, hook, resources) do
    case hook.(:session_started, resources) do
      :ok -> :ok
      _ -> {:error, recipe.session_failed_error()}
    end
  rescue
    _exception -> {:error, recipe.session_failed_error()}
  catch
    _kind, _reason -> {:error, recipe.session_failed_error()}
  end

  defp builder_fault(_recipe, nil, _stage, _resources), do: :ok

  defp builder_fault(recipe, hook, stage, resources) do
    case hook.(stage, resources) do
      :ok -> :ok
      _other -> {:error, recipe.session_failed_error()}
    end
  end

  defp profile_error(profile_id, function, fallback) do
    case AnalysisProfileRegistry.fetch(profile_id) do
      {:ok, recipe} -> {:error, apply(recipe, function, [])}
      {:error, _reason} -> {:error, fallback}
    end
  end

  defp normalize_error(reason, _recipe) when is_atom(reason), do: reason
  defp normalize_error(_reason, recipe), do: recipe.session_failed_error()
  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
