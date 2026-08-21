defmodule PtcRunner.Kernel.ProjectResolver do
  @moduledoc false

  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandParser
  alias PtcRunner.Kernel.CommandProjectDiagnostic
  alias PtcRunner.Kernel.CommandRejection
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.ProjectContext

  @project_commands ~w(validate run doctor models)

  @spec parse([binary()], :standalone | :mix, binary()) ::
          {:ok, CommandArguments.t()}
          | {:document_error, CommandArguments.t(), CommandDiagnostic.t()}
          | {:error, CommandRejection.t()}
  def parse(argv, frontend, run_ref)
      when is_list(argv) and frontend in [:standalone, :mix] and is_binary(run_ref) do
    case expand(argv, run_ref) do
      {:ok, expanded, project, derived} ->
        case CommandParser.parse(expanded, frontend) do
          {:ok, arguments} ->
            {:ok, %{arguments | project: context(project, derived)}}

          # The parser decides first, so an unknown switch, a duplicate, or a
          # terminator still reports itself. Only its unqualified verdict is
          # reconsidered, and only when a supplied project explains it.
          {:error, %CommandRejection{} = rejection} ->
            {:error, undeclared_host_rejection(rejection, project, expanded, frontend)}
        end

      {:error, %CommandRejection{} = rejection} ->
        {:error, rejection}

      {:document_error, expanded, reason} ->
        document_error(expanded, frontend, reason)

      {:error, command} ->
        {:error, CommandRejection.generic(command, :invalid_arguments)}
    end
  rescue
    _exception -> {:error, CommandRejection.generic(:unknown, :invalid_arguments)}
  catch
    _kind, _reason -> {:error, CommandRejection.generic(:unknown, :invalid_arguments)}
  end

  def parse(_argv, _frontend, _run_ref),
    do: {:error, CommandRejection.generic(:unknown, :invalid_arguments)}

  defp expand([command, path | rest] = argv, run_ref) when command in @project_commands do
    if String.starts_with?(path, "-") do
      {:ok, argv, nil, []}
    else
      expand_positional(command, path, rest, run_ref)
    end
  end

  defp expand(["repl" | rest] = argv, run_ref), do: expand_repl(argv, rest, run_ref)
  defp expand(argv, _run_ref), do: {:ok, argv, nil, []}

  defp expand_positional(command, path, rest, run_ref) do
    case ProjectConfig.classify(path) do
      :application ->
        {:ok, [command, path | rest], nil, []}

      {:project, project} ->
        project_argv(command, rest, project, run_ref)

      # `classify/1` reads `kind` first and only rejects a document that names
      # itself a project, so its diagnostic has project-document authority. The
      # command line is parsed separately before that diagnostic is admitted.
      {:error, {:project_schema_invalid, _violation} = reason} ->
        {:document_error, [command, path | rest], reason}

      {:error, _reason} ->
        {:error, CommandRejection.generic(command_atom(command), :invalid_arguments)}
    end
  end

  defp document_error(["models", _project_path | rest], frontend, reason) do
    if switch?(rest, "--host-config") do
      # A project and an explicit host are conflicting authority modes, but the
      # shared parser still owns switch syntax and duplicate detection. Let it
      # reject those faults before collapsing an otherwise valid parse to the
      # authority conflict.
      case CommandParser.parse(["models" | rest], frontend) do
        {:ok, _arguments} -> {:error, CommandRejection.generic(:models, :invalid_arguments)}
        {:error, %CommandRejection{} = rejection} -> {:error, rejection}
      end
    else
      ["models" | rest]
      |> insert_options(["--host-config", "ptc-host.json"])
      |> parse_document_error(frontend, reason)
      |> without_synthetic_host()
    end
  end

  defp document_error(["doctor", project_path | rest], frontend, reason) do
    if switch?(rest, "--connect") and not switch?(rest, "--host-config") do
      parse_document_error(
        insert_options(
          ["doctor", project_path | rest],
          ["--host-config", "ptc-host.json"]
        ),
        frontend,
        reason
      )
      |> without_synthetic_host()
    else
      parse_document_error(["doctor", project_path | rest], frontend, reason)
    end
  end

  defp document_error(argv, frontend, reason), do: parse_document_error(argv, frontend, reason)

  defp parse_document_error(argv, frontend, reason) do
    case CommandParser.parse(argv, frontend) do
      {:ok, arguments} ->
        {:document_error, arguments, CommandProjectDiagnostic.project(reason)}

      {:error, %CommandRejection{} = rejection} ->
        {:error, rejection}
    end
  end

  # `models` and active `doctor` require the host path that a valid project
  # would derive before they reach `CommandParser`. A fixed placeholder lets the
  # shared parser validate only their remaining syntax; it is removed before
  # the admitted terminal entry can be observed or bootstrapped.
  defp without_synthetic_host({:document_error, arguments, diagnostic}) do
    {:document_error,
     %{
       arguments
       | options: Map.delete(arguments.options, :host_config),
         ordered_options: Keyword.delete(arguments.ordered_options, :host_config)
     }, diagnostic}
  end

  defp without_synthetic_host(result), do: result

  # The resolver is the only layer that knows a project was supplied and that it
  # declares no host. Downstream sees an absent `--host-config` and can only
  # report the arguments, which are exactly what `--help` prints for both of
  # these commands.
  # A project and `--host-config` are documented alternatives, so combining them
  # stays an argument fault whether or not the project declares a host —
  # otherwise the project argument would be silently ignored. Without the
  # switch nothing is added, the parser rejects for itself, and
  # `undeclared_host_rejection/4` supplies the reason.
  defp project_argv("models", rest, %ProjectConfig{host: nil} = project, _run_ref) do
    if switch?(rest, "--host-config"),
      do: {:error, :models},
      else: {:ok, ["models" | rest], project, []}
  end

  defp project_argv("models", rest, project, _run_ref) do
    if switch?(rest, "--host-config") do
      {:error, :models}
    else
      {:ok, insert_options(["models" | rest], ["--host-config", project.host]), project,
       [:host_config]}
    end
  end

  defp project_argv(command, rest, project, run_ref) do
    base = [command, project.application | rest]
    {argv, derived} = add_host(base, rest, project, [])
    {argv, derived} = add_environment(command, argv, rest, project, derived)
    {argv, derived} = add_artifacts(command, argv, rest, project, run_ref, derived)
    {:ok, argv, project, derived}
  end

  # `models` needs an installed host to list, and `doctor --connect` needs one
  # to reach. Passive `doctor`, `run`, `validate`, and `repl --project` do not,
  # and a project declaring no host is ordinary for them.
  defp undeclared_host_rejection(
         %CommandRejection{kind: :generic, code: :invalid_arguments, command: command},
         %ProjectConfig{host: nil},
         argv,
         frontend
       )
       when command in [:models, :doctor] do
    argv
    |> insert_options(["--host-config", "ptc-host.json"])
    |> CommandParser.parse(frontend)
    |> case do
      {:ok, _arguments} -> CommandRejection.undeclared_project_host(command)
      {:error, %CommandRejection{} = rejection} -> rejection
    end
  end

  defp undeclared_host_rejection(rejection, _project, _argv, _frontend), do: rejection

  defp expand_repl(argv, rest, _run_ref) do
    case take_project(rest) do
      :none ->
        {:ok, argv, nil, []}

      {:error, _reason} ->
        {:error, :repl}

      {:ok, project_path, option_arguments, positional_suffix} ->
        expand_repl_project(project_path, option_arguments, positional_suffix)
    end
  end

  defp expand_repl_project(project_path, option_arguments, positional_suffix) do
    with false <-
           Enum.any?(
             ["--manifest", "-m", "--describe-profile"],
             &switch?(option_arguments, &1)
           ),
         {:ok, project} <- ProjectConfig.load(project_path) do
      expand_loaded_repl_project(project, option_arguments, positional_suffix)
    else
      true -> {:error, CommandRejection.generic(:repl, :conflicting_arguments)}
      {:error, _reason} -> {:error, :repl}
    end
  end

  defp expand_loaded_repl_project(project, option_arguments, positional_suffix) do
    case option_value(option_arguments, "--profile") do
      nil ->
        argv = insert_options(["repl" | option_arguments], ["--manifest", project.application])
        derived = [:manifest]
        {argv, derived} = add_host(argv, option_arguments, project, derived)
        {argv, derived} = add_environment("repl", argv, option_arguments, project, derived)
        {:ok, argv ++ positional_suffix, project, derived}

      profile ->
        {argv, derived} =
          add_profile_resources(
            ["repl" | option_arguments],
            option_arguments,
            project,
            profile,
            []
          )

        {:ok, argv ++ positional_suffix, project, derived}
    end
  end

  defp take_project(arguments), do: take_project(arguments, [], nil)

  defp take_project([], _acc, nil), do: :none

  defp take_project([], acc, found) when is_binary(found),
    do: {:ok, found, Enum.reverse(acc), []}

  defp take_project(["--" | _rest], _acc, nil), do: :none

  defp take_project(["--" | rest], acc, found) when is_binary(found),
    do: {:ok, found, Enum.reverse(acc), ["--" | rest]}

  defp take_project(["--project", value | rest], acc, nil) when value != "" do
    take_project(rest, acc, value)
  end

  defp take_project(["--project=" <> value | rest], acc, nil) when value != "" do
    take_project(rest, acc, value)
  end

  defp take_project(["--project" | _rest], _acc, _found), do: {:error, :missing_project}
  defp take_project(["--project=" | _rest], _acc, _found), do: {:error, :missing_project}

  defp take_project([argument | rest], acc, found),
    do: take_project(rest, [argument | acc], found)

  defp add_host(argv, rest, %ProjectConfig{host: host}, derived) when is_binary(host) do
    if switch?(rest, "--host-config"),
      do: {argv, derived},
      else: {insert_options(argv, ["--host-config", host]), put_derived(derived, :host_config)}
  end

  defp add_host(argv, _rest, _project, derived), do: {argv, derived}

  defp add_environment(command, argv, rest, %ProjectConfig{env_file: env_file}, derived)
       when command in ["run", "repl"] and is_binary(env_file) do
    if switch?(rest, "--env-file"),
      do: {argv, derived},
      else: {insert_options(argv, ["--env-file", env_file]), put_derived(derived, :env_file)}
  end

  defp add_environment("doctor", argv, rest, %ProjectConfig{env_file: env_file}, derived)
       when is_binary(env_file) do
    if switch?(rest, "--connect") and not switch?(rest, "--env-file"),
      do: {insert_options(argv, ["--env-file", env_file]), put_derived(derived, :env_file)},
      else: {argv, derived}
  end

  defp add_environment(_command, argv, _rest, _project, derived), do: {argv, derived}

  defp add_artifacts(
         "run",
         argv,
         rest,
         %ProjectConfig{artifact_root: root} = project,
         run_ref,
         derived
       )
       when is_binary(root) do
    {argv, derived} =
      maybe_add_artifact(
        argv,
        rest,
        project.artifacts.trace,
        "--trace-dir",
        :trace_dir,
        Path.join(root, "traces"),
        derived
      )

    {argv, derived} =
      maybe_add_artifact(
        argv,
        rest,
        project.artifacts.inspection,
        "--inspect",
        :inspect,
        Path.join([root, "inspection", run_ref <> ".inspection.jsonl"]),
        derived
      )

    {argv, derived} =
      if project.artifacts.result and
           not Enum.any?(["--output", "--private-output"], &switch?(rest, &1)) do
        {insert_options(argv, ["--output", Path.join([root, "results", run_ref <> ".json"])]),
         put_derived(derived, :result)}
      else
        {argv, derived}
      end

    # The project envelope is a ledger: retain its root requirement even when
    # the caller also asked for `--envelope FILE`, so the convenience copy never
    # suppresses `.ptc/envelopes/<run_ref>.json`. Only the switch injected here
    # is project-derived; an explicit frontend option must keep its provenance.
    add_envelope_artifact(argv, rest, project.artifacts.envelope, root, run_ref, derived)
  end

  defp add_artifacts(_command, argv, _rest, _project, _run_ref, derived), do: {argv, derived}

  defp add_envelope_artifact(argv, _rest, false, _root, _run_ref, derived),
    do: {argv, derived}

  defp add_envelope_artifact(argv, rest, true, root, run_ref, derived) do
    derived = put_derived(derived, :envelope_ledger)
    ledger = Path.join([root, "envelopes", run_ref <> ".json"])

    if switch?(rest, "--envelope"),
      do: {argv, derived},
      else: {insert_options(argv, ["--envelope", ledger]), put_derived(derived, :envelope)}
  end

  defp add_profile_resources(
         argv,
         rest,
         %ProjectConfig{artifact_root: root, artifacts: artifacts},
         profile,
         derived
       )
       when is_binary(root) do
    {argv, derived} =
      maybe_add_profile_resource(
        argv,
        rest,
        profile in ["run-analysis-v1", "private-run-analysis-v1"] and artifacts.trace,
        "traces",
        Path.join(root, "traces"),
        derived
      )

    maybe_add_profile_resource(
      argv,
      rest,
      profile == "private-run-analysis-v1" and artifacts.inspection,
      "inspection",
      Path.join(root, "inspection"),
      derived
    )
  end

  defp add_profile_resources(argv, _rest, _project, _profile, derived), do: {argv, derived}

  defp maybe_add_profile_resource(argv, rest, true, name, path, derived) do
    if resource_named?(rest, name),
      do: {argv, derived},
      else:
        {insert_options(argv, ["--resource", "#{name}=#{path}"]), put_derived(derived, :resource)}
  end

  defp maybe_add_profile_resource(argv, _rest, false, _name, _path, derived),
    do: {argv, derived}

  defp maybe_add_artifact(argv, rest, true, switch, key, value, derived) do
    if switch?(rest, switch),
      do: {argv, derived},
      else: {insert_options(argv, [switch, value]), put_derived(derived, key)}
  end

  defp maybe_add_artifact(argv, _rest, false, _switch, _key, _value, derived),
    do: {argv, derived}

  defp switch?(arguments, switch) do
    arguments
    |> Enum.take_while(&(&1 != "--"))
    |> Enum.any?(&(&1 == switch or String.starts_with?(&1, switch <> "=")))
  end

  defp option_value(["--" | _rest], _switch), do: nil
  defp option_value([switch, value | _rest], switch) when value != "", do: value

  defp option_value([argument | rest], switch) do
    case String.split(argument, "=", parts: 2) do
      [^switch, value] when value != "" -> value
      _other -> option_value(rest, switch)
    end
  end

  defp option_value([], _switch), do: nil

  defp resource_named?(["--" | _rest], _name), do: false

  defp resource_named?(["--resource", value | rest], name),
    do: String.starts_with?(value, name <> "=") or resource_named?(rest, name)

  defp resource_named?(["--resource=" <> value | rest], name),
    do: String.starts_with?(value, name <> "=") or resource_named?(rest, name)

  defp resource_named?([_argument | rest], name), do: resource_named?(rest, name)
  defp resource_named?([], _name), do: false

  defp insert_options(argv, options) do
    {option_arguments, positional_suffix} = Enum.split_while(argv, &(&1 != "--"))
    option_arguments ++ options ++ positional_suffix
  end

  defp context(nil, _derived), do: nil

  defp context(project, derived),
    do: %ProjectContext{config: project, derived_options: MapSet.new(derived)}

  defp put_derived(derived, option), do: [option | derived]

  defp command_atom("validate"), do: :validate
  defp command_atom("run"), do: :run
  defp command_atom("doctor"), do: :doctor
  defp command_atom("models"), do: :models
end
