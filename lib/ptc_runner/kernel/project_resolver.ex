defmodule PtcRunner.Kernel.ProjectResolver do
  @moduledoc false

  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandParser
  alias PtcRunner.Kernel.CommandRejection
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.ProjectContext

  @project_commands ~w(validate run doctor models)

  @spec parse([binary()], :standalone | :mix, binary()) ::
          {:ok, CommandArguments.t()} | {:error, CommandRejection.t()}
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
            {:error, undeclared_host_rejection(rejection, project)}
        end

      {:error, %CommandRejection{} = rejection} ->
        {:error, rejection}

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

      {:error, _reason} ->
        {:error, command_atom(command)}
    end
  end

  # The resolver is the only layer that knows a project was supplied and that it
  # declares no host. Downstream sees an absent `--host-config` and can only
  # report the arguments, which are exactly what `--help` prints for both of
  # these commands.
  # A project and `--host-config` are documented alternatives, so combining them
  # stays an argument fault whether or not the project declares a host —
  # otherwise the project argument would be silently ignored. Without the
  # switch nothing is added, the parser rejects for itself, and
  # `undeclared_host_rejection/2` supplies the reason.
  defp project_argv("models", rest, %ProjectConfig{host: nil} = project, _run_ref) do
    if switch?(rest, "--host-config"),
      do: {:error, :models},
      else: {:ok, ["models" | rest], project, []}
  end

  defp project_argv("models", rest, project, _run_ref) do
    if switch?(rest, "--host-config") do
      {:error, :models}
    else
      {:ok, ["models" | rest] ++ ["--host-config", project.host], project, [:host_config]}
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
         %ProjectConfig{host: nil}
       )
       when command in [:models, :doctor],
       do: CommandRejection.undeclared_project_host(command)

  defp undeclared_host_rejection(rejection, _project), do: rejection

  defp expand_repl(argv, rest, _run_ref) do
    case take_project(rest) do
      :none ->
        {:ok, argv, nil, []}

      {:error, _reason} ->
        {:error, :repl}

      {:ok, project_path, option_arguments, positional_suffix} ->
        if Enum.any?(
             ["--manifest", "-m", "--profile", "--describe-profile"],
             &switch?(option_arguments, &1)
           ) do
          {:error, CommandRejection.generic(:repl, :conflicting_arguments)}
        else
          case ProjectConfig.load(project_path) do
            {:ok, project} ->
              argv = ["repl" | option_arguments] ++ ["--manifest", project.application]
              derived = [:manifest]
              {argv, derived} = add_host(argv, option_arguments, project, derived)

              {argv, derived} =
                add_environment("repl", argv, option_arguments, project, derived)

              {:ok, argv ++ positional_suffix, project, derived}

            {:error, _reason} ->
              {:error, :repl}
          end
        end
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
      else: {argv ++ ["--host-config", host], put_derived(derived, :host_config)}
  end

  defp add_host(argv, _rest, _project, derived), do: {argv, derived}

  defp add_environment(command, argv, rest, %ProjectConfig{env_file: env_file}, derived)
       when command in ["run", "repl"] and is_binary(env_file) do
    if switch?(rest, "--env-file"),
      do: {argv, derived},
      else: {argv ++ ["--env-file", env_file], put_derived(derived, :env_file)}
  end

  defp add_environment("doctor", argv, rest, %ProjectConfig{env_file: env_file}, derived)
       when is_binary(env_file) do
    if switch?(rest, "--connect") and not switch?(rest, "--env-file"),
      do: {argv ++ ["--env-file", env_file], put_derived(derived, :env_file)},
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
        {argv ++ ["--output", Path.join([root, "results", run_ref <> ".json"])],
         put_derived(derived, :result)}
      else
        {argv, derived}
      end

    maybe_add_artifact(
      argv,
      rest,
      project.artifacts.envelope,
      "--envelope",
      :envelope,
      Path.join([root, "envelopes", run_ref <> ".json"]),
      derived
    )
  end

  defp add_artifacts(_command, argv, _rest, _project, _run_ref, derived), do: {argv, derived}

  defp maybe_add_artifact(argv, rest, true, switch, key, value, derived) do
    if switch?(rest, switch),
      do: {argv, derived},
      else: {argv ++ [switch, value], put_derived(derived, key)}
  end

  defp maybe_add_artifact(argv, _rest, false, _switch, _key, _value, derived),
    do: {argv, derived}

  defp switch?(arguments, switch) do
    Enum.any?(arguments, &(&1 == switch or String.starts_with?(&1, switch <> "=")))
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
