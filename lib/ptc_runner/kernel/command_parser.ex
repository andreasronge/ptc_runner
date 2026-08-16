defmodule PtcRunner.Kernel.CommandParser do
  @moduledoc """
  Shared strict parser for the stable standalone argv contract.

  It performs no filesystem or provider work. Each command obtains its strict
  switch vocabulary from `PtcRunner.Kernel.CommandDeclaration`. Duplicate,
  unknown, missing, conflicting, and misplaced arguments are rejected in phase
  1 without retaining unknown caller input.
  """

  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandDeclaration
  alias PtcRunner.Kernel.CommandRejection
  alias PtcRunner.Kernel.ViewerBinding

  @type frontend :: CommandDeclaration.frontend()

  @spec parse([binary()], frontend()) ::
          {:ok, CommandArguments.t()} | {:error, CommandRejection.t()}
  def parse(argv, frontend \\ :standalone)

  def parse(argv, frontend) when is_list(argv) and frontend in [:standalone, :mix] do
    if Enum.all?(argv, &is_binary/1),
      do: parse_argv(argv, frontend),
      else: reject(:unknown, :invalid_arguments)
  end

  def parse(_argv, _frontend), do: reject(:unknown, :invalid_arguments)

  defp parse_argv(argv, frontend) do
    if "--version" in Enum.take_while(argv, &(&1 != "--")) do
      if argv == ["--version"],
        do: arguments(:version),
        else: reject_closed_command(:version, List.delete(argv, "--version"), frontend)
    else
      dispatch_argv(argv, frontend)
    end
  end

  defp dispatch_argv(["version"], _frontend), do: arguments(:version)

  defp dispatch_argv(["version" | rest], frontend),
    do: reject_closed_command(:version, rest, frontend)

  defp dispatch_argv(["--help"], frontend), do: help(:root, frontend)
  defp dispatch_argv(["--help" | _rest], _frontend), do: reject(:help, :invalid_arguments)
  defp dispatch_argv([], frontend), do: help(:root, frontend)
  defp dispatch_argv(["help"], frontend), do: help(:root, frontend)

  defp dispatch_argv(["help", topic], frontend) do
    case CommandDeclaration.topic_atom(topic) do
      {:ok, topic} -> help(topic, frontend)
      :error -> reject(:help, :invalid_arguments)
    end
  end

  defp dispatch_argv(["help" | rest], frontend),
    do: reject_closed_command(:help, rest, frontend)

  defp dispatch_argv([command | argv], frontend) do
    case CommandDeclaration.command_atom(command) do
      {:ok, command} -> parse_command(command, argv, frontend)
      :error -> reject(:unknown, :invalid_command)
    end
  end

  defp parse_command(command, argv, frontend) do
    option_arguments = Enum.take_while(argv, &(&1 != "--"))

    if undeclared_raw_switch?(option_arguments, command, frontend) do
      {:error, CommandRejection.unknown_switch(command, frontend)}
    else
      parse_declared_command(command, argv, option_arguments, frontend)
    end
  end

  defp parse_declared_command(command, argv, option_arguments, frontend) do
    switches = CommandDeclaration.switches(command, frontend)
    aliases = CommandDeclaration.aliases(command, frontend)
    {options, positional, invalid} = OptionParser.parse(argv, strict: switches, aliases: aliases)

    cond do
      invalid != [] ->
        reject_invalid_switch(command, invalid, frontend)

      duplicate_options?(option_arguments, command, frontend) ->
        reject(command, :invalid_arguments)

      Keyword.has_key?(options, :help) ->
        validate_help_alias(command, positional, options, frontend)

      conflicting?(options, :input, :private_input) or
          conflicting?(options, :output, :private_output) ->
        reject(command, :conflicting_arguments)

      true ->
        {frontend_options, command_options} =
          Keyword.split(options, CommandDeclaration.frontend_option_keys(command, frontend))

        if frontend_options_valid?(frontend_options) do
          validate_command(
            command,
            positional,
            Map.new(command_options),
            options,
            frontend_options,
            frontend
          )
        else
          reject(command, :invalid_arguments)
        end
    end
  end

  # OptionParser helpfully expands boolean `--no-*` forms and bundled short
  # aliases. Neither spelling exists in the closed per-command declaration, so
  # reject them before normalization can turn them into declared keys.
  defp undeclared_raw_switch?(arguments, command, frontend) do
    value_switches = CommandDeclaration.value_switches(command, frontend)
    undeclared_raw_switch?(arguments, value_switches)
  end

  defp undeclared_raw_switch?([], _value_switches), do: false

  defp undeclared_raw_switch?([argument | rest], value_switches) do
    cond do
      argument in value_switches and rest != [] ->
        [value | remaining] = rest

        if option_parser_consumes_value?(value),
          do: undeclared_raw_switch?(remaining, value_switches),
          else: undeclared_raw_switch?(rest, value_switches)

      String.starts_with?(argument, "--no-") ->
        true

      compact_short_switch?(argument) ->
        true

      true ->
        undeclared_raw_switch?(rest, value_switches)
    end
  end

  defp compact_short_switch?("-" <> rest),
    do: byte_size(rest) > 1 and not String.starts_with?(rest, "-")

  defp compact_short_switch?(_argument), do: false

  defp option_parser_consumes_value?("-"), do: true

  defp option_parser_consumes_value?("-" <> rest) when rest != "",
    do: Regex.match?(~r/\A\d/, rest)

  defp option_parser_consumes_value?(_value), do: true

  defp validate_command(:init, [directory], options, ordered, frontend_options, frontend)
       when map_size(options) == 0,
       do:
         arguments(:init,
           directory: directory,
           ordered_options: ordered,
           frontend_options: frontend_options,
           frontend: frontend
         )

  defp validate_command(:validate, [application], options, ordered, frontend_options, frontend) do
    if allowed?(:validate, options, frontend),
      do:
        arguments(:validate,
          application: application,
          options: options,
          ordered_options: ordered,
          frontend_options: frontend_options,
          frontend: frontend
        ),
      else: reject(:validate, :invalid_arguments)
  end

  defp validate_command(:run, [application], options, ordered, frontend_options, frontend) do
    if allowed?(:run, options, frontend),
      do:
        arguments(:run,
          application: application,
          options: options,
          ordered_options: ordered,
          frontend_options: frontend_options,
          frontend: frontend
        ),
      else: reject(:run, :invalid_arguments)
  end

  defp validate_command(:doctor, positional, options, ordered, frontend_options, frontend)
       when length(positional) <= 1 do
    if allowed?(:doctor, options, frontend) and enabled_if_present?(options, :connect) and
         env_file_active_doctor?(options, frontend_options) do
      application = List.first(positional)

      if Map.get(options, :connect, false) and
           (is_nil(application) or not Map.has_key?(options, :host_config)),
         do: reject(:doctor, :invalid_arguments),
         else:
           arguments(:doctor,
             application: application,
             options: options,
             ordered_options: ordered,
             frontend_options: frontend_options,
             frontend: frontend
           )
    else
      reject(:doctor, :invalid_arguments)
    end
  end

  defp validate_command(
         :models,
         [],
         %{host_config: host_config} = options,
         ordered,
         frontend_options,
         frontend
       ) do
    if map_size(options) == 1 and allowed?(:models, options, frontend),
      do:
        arguments(:models,
          options: %{host_config: host_config},
          ordered_options: ordered,
          frontend_options: frontend_options,
          frontend: frontend
        ),
      else: reject(:models, :invalid_arguments)
  end

  defp validate_command(
         :transcript,
         [run_id],
         %{
           traces: traces,
           inspection: inspection,
           private_unattended: true,
           private_output: private_output
         } = options,
         ordered,
         [],
         frontend
       )
       when map_size(options) == 4 do
    if Enum.all?([run_id, traces, inspection, private_output], &valid_nonempty_string?/1) do
      arguments(:transcript,
        application: run_id,
        options: options,
        ordered_options: ordered,
        frontend: frontend
      )
    else
      reject(:transcript, :invalid_arguments)
    end
  end

  defp validate_command(:repl, positional, options, ordered, frontend_options, frontend)
       when length(positional) <= 1 do
    cond do
      not allowed?(:repl, options, frontend) ->
        reject(:repl, :invalid_arguments)

      not env_file_manifest_repl?(options, frontend_options) ->
        reject(:repl, :invalid_arguments)

      Map.get(options, :private_terminal, false) and
          Map.get(options, :private_unattended, false) ->
        reject(:repl, :conflicting_arguments)

      Map.has_key?(options, :eval) and positional != [] ->
        reject(:repl, :conflicting_arguments)

      not repl_arguments_valid?(options, ordered, positional) ->
        reject(:repl, :invalid_arguments)

      true ->
        arguments(:repl,
          application: List.first(positional),
          options: options,
          ordered_options: ordered,
          frontend_options: frontend_options,
          frontend: frontend
        )
    end
  end

  defp validate_command(:viewer, [project], options, ordered, frontend_options, frontend) do
    if allowed?(:viewer, options, frontend) and valid_nonempty_string?(project) and
         viewer_port_valid?(options) and viewer_listen_valid?(options) do
      arguments(:viewer,
        application: project,
        options: options,
        ordered_options: ordered,
        frontend_options: frontend_options,
        frontend: frontend
      )
    else
      reject(:viewer, :invalid_arguments)
    end
  end

  defp validate_command(command, _positional, _options, _ordered, _frontend_options, _frontend),
    do: reject(command, :invalid_arguments)

  defp viewer_port_valid?(options) do
    case Map.fetch(options, :port) do
      :error -> true
      {:ok, port} -> ViewerBinding.port(port) != :error
    end
  end

  defp viewer_listen_valid?(options) do
    case Map.fetch(options, :listen) do
      :error -> true
      {:ok, listen} -> ViewerBinding.address(listen) != :error
    end
  end

  defp validate_help_alias(command, [], [help: true], frontend), do: help(command, frontend)

  defp validate_help_alias(_command, _positional, options, frontend) do
    if length(options) > 1,
      do: {:error, CommandRejection.unknown_switch(:help, frontend)},
      else: reject(:help, :invalid_arguments)
  end

  defp repl_arguments_valid?(options, ordered, positional) do
    format = Map.get(options, :format, "clojure")
    evals = Keyword.get_values(ordered, :eval)
    resources = Keyword.get_values(ordered, :resource)

    cond do
      format not in ["clojure", "jsonl"] ->
        false

      Map.has_key?(options, :describe_profile) ->
        positional == [] and
          Map.keys(options) -- [:describe_profile, :format] == []

      Map.has_key?(options, :profile) ->
        profile_arguments_valid?(options, positional, evals, resources, format)

      Map.has_key?(options, :manifest) ->
        manifest_arguments_valid?(options, resources, format)

      true ->
        direct_arguments_valid?(options, format)
    end
  end

  defp profile_arguments_valid?(options, positional, evals, resources, format) do
    not Enum.any?([:manifest, :host_config, :trace], &Map.has_key?(options, &1)) and
      resources != [] and
      not (format == "jsonl" and evals == [] and positional == []) and
      not (Map.get(options, :continue_on_error, false) and length(evals) < 2) and
      profile_output_arguments_valid?(options, positional, evals)
  end

  defp profile_output_arguments_valid?(options, positional, evals) do
    output? = Map.has_key?(options, :output)
    private_output? = Map.has_key?(options, :private_output)

    if output? or private_output? do
      positional == [] and length(evals) == 1 and not Map.has_key?(options, :load) and
        not Map.get(options, :continue_on_error, false) and
        ((output? and options[:profile] == "run-analysis-v1" and
            not Map.get(options, :private_unattended, false)) or
           (private_output? and options[:profile] == "private-run-analysis-v1" and
              Map.get(options, :private_unattended, false)))
    else
      true
    end
  end

  defp manifest_arguments_valid?(options, resources, format) do
    allowed = [:eval, :load, :manifest, :host_config, :trace, :format, :private_terminal]

    resources == [] and format == "clojure" and Map.keys(options) -- allowed == []
  end

  defp direct_arguments_valid?(options, format) do
    allowed = [:eval, :load, :trace, :format]
    format == "clojure" and Map.keys(options) -- allowed == []
  end

  defp arguments(command, fields \\ []) do
    {:ok,
     %CommandArguments{
       command: command,
       application: Keyword.get(fields, :application),
       directory: Keyword.get(fields, :directory),
       options: Keyword.get(fields, :options, %{}),
       ordered_options: Keyword.get(fields, :ordered_options, []),
       frontend: Keyword.get(fields, :frontend, :standalone),
       frontend_options: Keyword.get(fields, :frontend_options, [])
     }}
  end

  defp help(topic, frontend),
    do: arguments(:help, options: %{topic: topic}, frontend: frontend)

  defp allowed?(command, options, frontend),
    do: Map.keys(options) -- CommandDeclaration.option_keys(command, frontend) == []

  defp duplicate_options?(argv, command, frontend) do
    accepted = CommandDeclaration.accepted_switches(command, frontend)
    repeatable = CommandDeclaration.repeatable_switches(command, frontend)

    keys =
      argv
      |> Enum.flat_map(&switch_key(&1, accepted, command, frontend))
      |> Enum.reject(&(&1 in repeatable))

    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp switch_key("--" <> _option = argument, accepted, command, frontend) do
    argument
    |> String.split("=", parts: 2)
    |> hd()
    |> known_switch_key(accepted, command, frontend)
  end

  defp switch_key("-" <> _option = argument, accepted, command, frontend),
    do: known_switch_key(argument, accepted, command, frontend)

  defp switch_key(_argument, _accepted, _command, _frontend), do: []

  defp known_switch_key(name, accepted, command, frontend) do
    if name in accepted,
      do: [CommandDeclaration.canonical_switch(command, frontend, name)],
      else: []
  end

  defp conflicting?(options, left, right),
    do: Keyword.has_key?(options, left) and Keyword.has_key?(options, right)

  defp enabled_if_present?(options, name),
    do: not Map.has_key?(options, name) or Map.fetch!(options, name) == true

  defp env_file_active_doctor?(options, frontend_options),
    do: not Keyword.has_key?(frontend_options, :env_file) or Map.get(options, :connect) == true

  defp env_file_manifest_repl?(options, frontend_options),
    do: not Keyword.has_key?(frontend_options, :env_file) or Map.has_key?(options, :manifest)

  defp frontend_options_valid?(options) do
    authorizations = Keyword.get_values(options, :authorize_mcp)

    length(authorizations) <= 128 and authorizations == Enum.uniq(authorizations) and
      Enum.all?(authorizations, &valid_authorization_name?/1) and env_file_valid?(options)
  end

  defp env_file_valid?(options) do
    case Keyword.fetch(options, :env_file) do
      :error -> true
      {:ok, path} -> valid_nonempty_string?(path)
    end
  end

  defp valid_nonempty_string?(value),
    do: is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value)

  defp valid_authorization_name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..128 and String.valid?(name) and
        Regex.match?(~r/\A[a-z][a-z0-9._-]{0,127}\z/, name)

  defp reject_invalid_switch(command, invalid, frontend) do
    accepted = CommandDeclaration.accepted_switches(command, frontend)
    reject_unknown_or_generic(command, invalid, accepted, frontend)
  end

  defp reject_unknown_or_generic(command, invalid, accepted, frontend) do
    if Enum.any?(invalid, fn {raw, _value} -> raw not in accepted end),
      do: {:error, CommandRejection.unknown_switch(command, frontend)},
      else: reject(command, :invalid_arguments)
  end

  defp reject_closed_command(command, arguments, frontend) do
    if Enum.any?(arguments, &String.starts_with?(&1, "--")),
      do: {:error, CommandRejection.unknown_switch(command, frontend)},
      else: reject(command, :invalid_arguments)
  end

  defp reject(command, code), do: {:error, CommandRejection.generic(command, code)}
end
