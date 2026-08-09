defmodule PtcRunner.Kernel.CommandDeclaration do
  @moduledoc """
  Closed per-command grammar and help declarations.

  The strict parser and the public help result both derive their switch lists
  from this module. A declaration contains no caller input and performs no
  filesystem or runtime work.
  """

  @shared_frontends [:standalone, :mix]
  @help_option %{
    key: :help,
    type: :boolean,
    syntax: ["--help"],
    description: "show help for this command"
  }

  @declarations %{
    root: %{
      usage: [
        "ptc validate ptc.json [--host-config HOST.json]",
        "ptc run ptc.json [OPTIONS]",
        "ptc doctor [ptc.json] [--host-config HOST.json] [--connect]",
        "ptc models --host-config HOST.json",
        "ptc init DIRECTORY",
        "ptc repl [OPTIONS] [SCRIPT|-]",
        "ptc --version"
      ],
      options: [
        %{key: :help, type: :boolean, syntax: ["--help"], description: "show root help"},
        %{
          key: :version,
          type: :boolean,
          syntax: ["--version"],
          description: "show the command version"
        }
      ],
      retired: %{}
    },
    init: %{
      usage: ["ptc init DIRECTORY"],
      options: [
        %{
          key: :envelope,
          type: :string,
          syntax: ["--envelope ENVELOPE.json"],
          description: "atomically publish the V1 command envelope"
        },
        @help_option
      ],
      retired: %{}
    },
    validate: %{
      usage: ["ptc validate ptc.json [--host-config HOST.json]"],
      options: [
        %{
          key: :host_config,
          type: :string,
          syntax: ["--host-config HOST.json"],
          description: "trusted provider installation document"
        },
        %{
          key: :envelope,
          type: :string,
          syntax: ["--envelope ENVELOPE.json"],
          description: "atomically publish the V1 command envelope"
        },
        @help_option
      ],
      retired: %{}
    },
    run: %{
      usage: ["ptc run ptc.json [OPTIONS]"],
      options: [
        %{
          key: :host_config,
          type: :string,
          syntax: ["--host-config HOST.json"],
          description: "trusted provider installation document"
        },
        %{
          key: :input,
          type: :string,
          syntax: ["--input INPUT.json"],
          description: "normal alternate input object"
        },
        %{
          key: :private_input,
          type: :string,
          syntax: ["--private-input INPUT.json"],
          description: "private alternate input object"
        },
        %{
          key: :trace_dir,
          type: :string,
          syntax: ["--trace-dir DIRECTORY"],
          description: "directory for the run-reference trace artifact"
        },
        %{
          key: :output,
          type: :string,
          syntax: ["--output VALUE.json"],
          description: "normal result artifact"
        },
        %{
          key: :private_output,
          type: :string,
          syntax: ["--private-output VALUE.json"],
          description: "owner-only private result artifact"
        },
        %{
          key: :inspect,
          type: :string,
          syntax: ["--inspect RUN.inspection.jsonl"],
          description: "owner-only private inspection artifact"
        },
        %{
          key: :component_override_descriptor,
          type: :string,
          syntax: ["--component-override-descriptor DESCRIPTOR.json"],
          description: "verified replacement component descriptor"
        },
        %{
          key: :envelope,
          type: :string,
          syntax: ["--envelope ENVELOPE.json"],
          description: "atomically publish the V1 command envelope"
        },
        %{
          key: :authorize_mcp,
          type: [:string, :keep],
          syntax: ["--authorize-mcp NAME"],
          description: "authorize one selected MCP installation for this run",
          frontends: [:mix],
          owner: :frontend,
          repeatable: true
        },
        @help_option
      ],
      retired: %{
        "--mission" => "--input",
        "--private-mission" => "--private-input",
        "--trace" => "--trace-dir",
        "--check" => "ptc validate"
      }
    },
    doctor: %{
      usage: ["ptc doctor [ptc.json] [--host-config HOST.json] [--connect]"],
      options: [
        %{
          key: :host_config,
          type: :string,
          syntax: ["--host-config HOST.json"],
          description: "trusted provider installation document"
        },
        %{
          key: :connect,
          type: :boolean,
          syntax: ["--connect"],
          description: "perform active provider checks"
        },
        %{
          key: :envelope,
          type: :string,
          syntax: ["--envelope ENVELOPE.json"],
          description: "atomically publish the V1 command envelope"
        },
        @help_option
      ],
      retired: %{}
    },
    models: %{
      usage: ["ptc models --host-config HOST.json"],
      options: [
        %{
          key: :host_config,
          type: :string,
          syntax: ["--host-config HOST.json"],
          description: "trusted provider installation document"
        },
        %{
          key: :envelope,
          type: :string,
          syntax: ["--envelope ENVELOPE.json"],
          description: "atomically publish the V1 command envelope"
        },
        @help_option
      ],
      retired: %{}
    },
    repl: %{
      usage: ["ptc repl [OPTIONS] [SCRIPT|-]"],
      options: [
        %{
          key: :eval,
          type: [:string, :keep],
          syntax: ["-e EXPR", "--eval EXPR"],
          description: "evaluate an expression; repeatable and ordered",
          aliases: [:e],
          repeatable: true
        },
        %{
          key: :load,
          type: :string,
          syntax: ["-l SETUP.clj", "--load SETUP.clj"],
          description: "evaluate a setup file before other input",
          aliases: [:l]
        },
        %{
          key: :manifest,
          type: :string,
          syntax: ["-m MANIFEST", "--manifest MANIFEST"],
          description: "reuse a strict Kernel manifest workflow",
          aliases: [:m]
        },
        %{
          key: :host_config,
          type: :string,
          syntax: ["--host-config HOST.json"],
          description: "manifest-only trusted provider installation document"
        },
        %{
          key: :trace,
          type: :string,
          syntax: ["-t TRACE.jsonl", "--trace TRACE.jsonl"],
          description: "append canonical session events",
          aliases: [:t]
        },
        %{
          key: :profile,
          type: :string,
          syntax: ["--profile PROFILE"],
          description: "select a code-owned analysis profile"
        },
        %{
          key: :resource,
          type: [:string, :keep],
          syntax: ["--resource NAME=DIRECTORY"],
          description: "supply a profile resource; repeatable and ordered",
          repeatable: true
        },
        %{
          key: :session_trace_dir,
          type: :string,
          syntax: ["--session-trace-dir DIRECTORY"],
          description: "existing directory for the profile session trace"
        },
        %{
          key: :format,
          type: :string,
          syntax: ["--format clojure|jsonl"],
          description: "choose human or JSON Lines profile output"
        },
        %{
          key: :continue_on_error,
          type: :boolean,
          syntax: ["--continue-on-error"],
          description: "continue later repeated evaluations after an error"
        },
        %{
          key: :private_terminal,
          type: :boolean,
          syntax: ["--private-terminal"],
          description: "authorize an attached terminal as the private sink"
        },
        %{
          key: :private_unattended,
          type: :boolean,
          syntax: ["--private-unattended"],
          description: "authorize this command's streams as the private sink"
        },
        %{
          key: :describe_profile,
          type: :string,
          syntax: ["--describe-profile PROFILE"],
          description: "print a safe static profile contract"
        },
        %{
          key: :help,
          type: :boolean,
          syntax: ["-h", "--help"],
          description: "show repl help without starting a session",
          aliases: [:h]
        }
      ],
      retired: %{}
    }
  }

  @commands [:init, :validate, :run, :doctor, :models, :repl]
  @topics [:root | @commands]

  @type command :: :init | :validate | :run | :doctor | :models | :repl
  @type topic :: :root | command()
  @type frontend :: :standalone | :mix

  @spec commands() :: [command()]
  def commands, do: @commands

  @spec topics() :: [topic()]
  def topics, do: @topics

  @spec command_atom(binary()) :: {:ok, command()} | :error
  def command_atom(name) when is_binary(name) do
    Enum.find_value(@commands, :error, fn command ->
      if Atom.to_string(command) == name, do: {:ok, command}, else: false
    end)
  end

  def command_atom(_name), do: :error

  @spec topic_atom(binary()) :: {:ok, topic()} | :error
  def topic_atom("root"), do: {:ok, :root}
  def topic_atom(name), do: command_atom(name)

  @spec switches(command(), frontend()) :: keyword()
  def switches(command, frontend \\ :standalone)

  def switches(command, frontend) when command in @commands and frontend in @shared_frontends do
    command
    |> options(frontend)
    |> Enum.map(&{&1.key, &1.type})
  end

  @spec aliases(command(), frontend()) :: keyword()
  def aliases(command, frontend \\ :standalone) do
    command
    |> options(frontend)
    |> Enum.flat_map(fn option ->
      Enum.map(Map.get(option, :aliases, []), &{&1, option.key})
    end)
  end

  @spec accepted_switches(command(), frontend()) :: [binary()]
  def accepted_switches(command, frontend \\ :standalone)

  def accepted_switches(command, frontend)
      when command in @commands and frontend in @shared_frontends do
    command
    |> options(frontend)
    |> Enum.flat_map(&switch_names/1)
  end

  @spec option_keys(command(), frontend()) :: [atom()]
  def option_keys(command, frontend \\ :standalone) do
    command
    |> options(frontend)
    |> Enum.map(& &1.key)
  end

  @spec frontend_option_keys(command(), frontend()) :: [atom()]
  def frontend_option_keys(command, frontend) do
    command
    |> options(frontend)
    |> Enum.filter(&(Map.get(&1, :owner, :command) == :frontend or &1.key == :envelope))
    |> Enum.map(& &1.key)
  end

  @spec repeatable_switches(command(), frontend()) :: [binary()]
  def repeatable_switches(command, frontend) do
    command
    |> options(frontend)
    |> Enum.filter(&Map.get(&1, :repeatable, false))
    |> Enum.map(&canonical_switch/1)
  end

  @spec value_switches(command(), frontend()) :: [binary()]
  def value_switches(command, frontend) do
    command
    |> options(frontend)
    |> Enum.filter(fn option ->
      option.type == :string or
        (is_list(option.type) and :string in option.type)
    end)
    |> Enum.flat_map(&switch_names/1)
  end

  @spec canonical_switch(command(), frontend(), binary()) :: binary() | nil
  def canonical_switch(command, frontend, switch) do
    command
    |> options(frontend)
    |> Enum.find_value(fn option ->
      if switch in switch_names(option), do: canonical_switch(option), else: false
    end)
  end

  @doc false
  @spec option_switch!(command(), frontend(), atom()) :: binary()
  def option_switch!(command, frontend, key)
      when command in @commands and frontend in @shared_frontends and is_atom(key) do
    command
    |> options(frontend)
    |> Enum.find(&(&1.key == key))
    |> canonical_switch()
  end

  @spec usage(topic()) :: [binary()]
  def usage(topic) when topic in @topics,
    do: @declarations |> Map.fetch!(topic) |> Map.fetch!(:usage)

  @spec help_options(topic(), frontend()) :: [map()]
  def help_options(topic, frontend \\ :standalone)

  def help_options(topic, frontend)
      when topic in @topics and frontend in @shared_frontends do
    topic
    |> options(frontend)
    |> Enum.map(fn option ->
      %{
        "switches" => option.syntax,
        "description" => option.description
      }
    end)
  end

  @spec retired_switch(command(), binary()) :: {:ok, binary()} | :error
  def retired_switch(command, switch) when command in @commands and is_binary(switch) do
    @declarations
    |> Map.fetch!(command)
    |> Map.fetch!(:retired)
    |> Map.fetch(switch)
  end

  def retired_switch(_command, _switch), do: :error

  defp options(topic, frontend) when topic in @topics and frontend in @shared_frontends do
    @declarations
    |> Map.fetch!(topic)
    |> Map.fetch!(:options)
    |> Enum.filter(&(frontend in Map.get(&1, :frontends, @shared_frontends)))
  end

  defp switch_names(option),
    do: Enum.map(option.syntax, &(&1 |> String.split(" ", parts: 2) |> hd()))

  defp canonical_switch(option) do
    Enum.find(switch_names(option), &String.starts_with?(&1, "--")) || hd(switch_names(option))
  end
end
