defmodule PtcRunner.Kernel.CommandParser do
  @moduledoc """
  Shared strict parser for the stable standalone argv contract.

  It performs no filesystem or provider work. Duplicate, unknown, missing,
  conflicting, and misplaced arguments are rejected in phase 1.
  """

  alias PtcRunner.Kernel.CommandArguments

  @commands ~w(init validate run doctor models)
  @help_topics ~w(init validate run doctor models)

  @switches [
    help: :boolean,
    version: :boolean,
    host_config: :string,
    input: :string,
    private_input: :string,
    trace_dir: :string,
    output: :string,
    private_output: :string,
    inspect: :string,
    component_override_descriptor: :string,
    connect: :boolean
  ]
  @switch_names Map.new(@switches, fn {name, _type} ->
                  {name |> Atom.to_string() |> String.replace("_", "-"), name}
                end)

  @spec parse([binary()]) ::
          {:ok, CommandArguments.t()}
          | {:error, atom(), :invalid_command | :invalid_arguments | :conflicting_arguments}
  def parse(argv) when is_list(argv) do
    if Enum.all?(argv, &is_binary/1),
      do: parse_argv(argv),
      else: {:error, :unknown, :invalid_arguments}
  end

  def parse(_argv), do: {:error, :unknown, :invalid_arguments}

  defp parse_argv(argv) do
    if "--version" in Enum.take_while(argv, &(&1 != "--")) do
      if argv == ["--version"],
        do: arguments(:version),
        else: {:error, :version, :invalid_arguments}
    else
      dispatch_argv(argv)
    end
  end

  defp dispatch_argv(["version"]), do: arguments(:version)
  defp dispatch_argv(["version" | _rest]), do: {:error, :version, :invalid_arguments}
  defp dispatch_argv(["--help"]), do: help(:root)
  defp dispatch_argv(["--help" | _rest]), do: {:error, :help, :invalid_arguments}
  defp dispatch_argv([]), do: help(:root)
  defp dispatch_argv(["help"]), do: help(:root)

  defp dispatch_argv(["help", topic]) when topic in @help_topics,
    do: help(String.to_existing_atom(topic))

  defp dispatch_argv(["help" | _rest]), do: {:error, :help, :invalid_arguments}

  defp dispatch_argv([command, "--help"]) when command in @help_topics,
    do: help(String.to_existing_atom(command))

  defp dispatch_argv([command, "--help" | _rest]) when command in @help_topics,
    do: {:error, :help, :invalid_arguments}

  defp dispatch_argv([command | argv]) when command in @commands do
    command
    |> String.to_existing_atom()
    |> parse_command(argv)
  end

  defp dispatch_argv(_argv), do: {:error, :unknown, :invalid_command}

  defp parse_command(command, argv) do
    option_arguments = Enum.take_while(argv, &(&1 != "--"))

    if Enum.any?(option_arguments, &underscored_long_switch?/1) do
      {:error, command, :invalid_arguments}
    else
      {options, positional, invalid} = OptionParser.parse(argv, strict: @switches)

      cond do
        invalid != [] or duplicate_options?(option_arguments) ->
          {:error, command, :invalid_arguments}

        conflicting?(options, :input, :private_input) or
            conflicting?(options, :output, :private_output) ->
          {:error, command, :conflicting_arguments}

        true ->
          validate_command(command, positional, Map.new(options))
      end
    end
  end

  defp validate_command(:init, [directory], options) when map_size(options) == 0,
    do: arguments(:init, directory: directory)

  defp validate_command(:validate, [application], options) do
    if allowed?(options, [:host_config]),
      do: arguments(:validate, application: application, options: options),
      else: {:error, :validate, :invalid_arguments}
  end

  defp validate_command(:run, [application], options) do
    allowed = [
      :host_config,
      :input,
      :private_input,
      :trace_dir,
      :output,
      :private_output,
      :inspect,
      :component_override_descriptor
    ]

    if allowed?(options, allowed),
      do: arguments(:run, application: application, options: options),
      else: {:error, :run, :invalid_arguments}
  end

  defp validate_command(:doctor, positional, options) when length(positional) <= 1 do
    if allowed?(options, [:host_config, :connect]) and enabled_if_present?(options, :connect) do
      application = List.first(positional)

      if Map.get(options, :connect, false) and
           (is_nil(application) or not Map.has_key?(options, :host_config)),
         do: {:error, :doctor, :invalid_arguments},
         else: arguments(:doctor, application: application, options: options)
    else
      {:error, :doctor, :invalid_arguments}
    end
  end

  defp validate_command(:models, [], %{host_config: host_config} = options)
       when map_size(options) == 1,
       do: arguments(:models, options: %{host_config: host_config})

  defp validate_command(command, _positional, _options),
    do: {:error, command, :invalid_arguments}

  defp arguments(command, fields \\ []) do
    {:ok,
     %CommandArguments{
       command: command,
       application: Keyword.get(fields, :application),
       directory: Keyword.get(fields, :directory),
       options: Keyword.get(fields, :options, %{})
     }}
  end

  defp help(topic),
    do: arguments(:help, options: %{topic: topic})

  defp allowed?(options, names), do: Map.keys(options) -- names == []

  defp duplicate_options?(argv) do
    keys = Enum.flat_map(argv, &switch_key/1)
    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp switch_key("--no-" <> name), do: known_switch_key(name)

  defp switch_key("--" <> option) do
    option
    |> String.split("=", parts: 2)
    |> hd()
    |> known_switch_key()
  end

  defp switch_key(_argument), do: []

  defp known_switch_key(name) do
    case Map.fetch(@switch_names, name) do
      {:ok, key} -> [key]
      :error -> []
    end
  end

  defp underscored_long_switch?("--" <> option) do
    option
    |> String.split("=", parts: 2)
    |> hd()
    |> String.contains?("_")
  end

  defp underscored_long_switch?(_argument), do: false

  defp conflicting?(options, left, right),
    do: Keyword.has_key?(options, left) and Keyword.has_key?(options, right)

  defp enabled_if_present?(options, name),
    do: not Map.has_key?(options, name) or Map.fetch!(options, name) == true
end
