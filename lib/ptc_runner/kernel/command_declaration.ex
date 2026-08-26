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
  @env_file_option %{
    key: :env_file,
    type: :string,
    syntax: ["--env-file FILE"],
    description: "load environment variables from this exact file",
    owner: :frontend
  }
  @envelope_option %{
    key: :envelope,
    type: :string,
    syntax: ["--envelope ENVELOPE.json"],
    description: "atomically publish the V3 command envelope"
  }
  @run_envelope_option %{
    key: :envelope,
    type: :string,
    syntax: ["--envelope ENVELOPE.json"],
    description:
      "atomically publish a V3 command envelope copy (project ledger still written when artifacts.envelope is enabled)"
  }

  @declarations %{
    root: %{
      usage: [
        "ptc validate MANIFEST.json|PROJECT.json [--host-config HOST.json]",
        "ptc run MANIFEST.json|PROJECT.json [OPTIONS]",
        "ptc doctor [MANIFEST.json|PROJECT.json] [--host-config HOST.json] [--connect]",
        "ptc models PROJECT.json | --host-config HOST.json",
        "ptc init DIRECTORY [--example NAME]",
        "ptc docs [PAGE]",
        "ptc help [COMMAND]",
        "ptc transcript RUN_ID --traces DIRECTORY --inspection DIRECTORY --private-unattended --private-output FILE",
        "ptc repl [OPTIONS] [SCRIPT|-]",
        "ptc viewer PROJECT.json [--port PORT] [--listen ADDRESS] [--env-file FILE]",
        "ptc version [--envelope ENVELOPE.json]",
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
      ]
    },
    init: %{
      usage: ["ptc init DIRECTORY [--example NAME]"],
      options: [
        %{
          key: :example,
          type: :string,
          syntax: ["--example NAME"],
          description: "materialize one embedded example tree instead of the scaffold"
        },
        @envelope_option,
        @help_option
      ]
    },
    version: %{
      usage: ["ptc version [--envelope ENVELOPE.json]"],
      options: [@envelope_option]
    },
    docs: %{
      usage: ["ptc docs [PAGE]"],
      options: [@help_option]
    },
    validate: %{
      usage: ["ptc validate MANIFEST.json|PROJECT.json [--host-config HOST.json]"],
      options: [
        %{
          key: :host_config,
          type: :string,
          syntax: ["--host-config HOST.json"],
          description: "trusted provider installation document"
        },
        @envelope_option,
        @help_option
      ]
    },
    run: %{
      usage: ["ptc run MANIFEST.json|PROJECT.json [OPTIONS]"],
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
          description:
            "normal alternate input object (application-relative document, or absolute/cwd path)"
        },
        %{
          key: :private_input,
          type: :string,
          syntax: ["--private-input INPUT.json"],
          description:
            "private alternate input object (application-relative document, or absolute/cwd path)"
        },
        %{
          key: :trace_dir,
          type: :string,
          syntax: ["--trace-dir DIRECTORY"],
          description: "existing directory for the run-reference trace artifact"
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
          syntax: ["--inspect RUN.ptcins"],
          description: "owner-only private inspection artifact"
        },
        %{
          key: :component_override_descriptor,
          type: :string,
          syntax: ["--component-override-descriptor DESCRIPTOR.json"],
          description: "verified replacement component descriptor"
        },
        @env_file_option,
        @run_envelope_option,
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
      ]
    },
    doctor: %{
      usage: [
        "ptc doctor [MANIFEST.json|PROJECT.json] [--host-config HOST.json] [--connect] [--show-model-selectors]"
      ],
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
          key: :show_model_selectors,
          type: :boolean,
          syntax: ["--show-model-selectors"],
          description: "include safe configured model selectors"
        },
        @env_file_option,
        @envelope_option,
        @help_option
      ]
    },
    models: %{
      usage: ["ptc models PROJECT.json | --host-config HOST.json"],
      options: [
        %{
          key: :host_config,
          type: :string,
          syntax: ["--host-config HOST.json"],
          description: "trusted provider installation document"
        },
        @envelope_option,
        @help_option
      ]
    },
    transcript: %{
      usage: [
        "ptc transcript RUN_ID --traces DIRECTORY --inspection DIRECTORY --private-unattended --private-output FILE"
      ],
      options: [
        %{
          key: :traces,
          type: :string,
          syntax: ["--traces DIRECTORY"],
          description: "trace directory; transcript selects RUN_ID.jsonl or RUN_ID.private.jsonl"
        },
        %{
          key: :inspection,
          type: :string,
          syntax: ["--inspection DIRECTORY"],
          description: "inspection directory; transcript selects RUN_ID.ptcins"
        },
        %{
          key: :private_unattended,
          type: :boolean,
          syntax: ["--private-unattended"],
          description: "explicitly authorize one unattended private result"
        },
        %{
          key: :private_output,
          type: :string,
          syntax: ["--private-output TRANSCRIPT.json"],
          description:
            "new owner-only file; parent must exist without a symlink (macOS /tmp is one) and be physically separate from --traces and --inspection"
        },
        @help_option
      ]
    },
    repl: %{
      usage: ["ptc repl [OPTIONS] [SCRIPT|-]"],
      options: [
        %{
          key: :project,
          type: :string,
          syntax: ["--project PROJECT.json"],
          description: "reuse application, host, and environment project defaults"
        },
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
          key: :mission,
          type: :string,
          syntax: ["--mission MISSION"],
          description: "open one manifest-declared mission environment"
        },
        %{
          key: :host_config,
          type: :string,
          syntax: ["--host-config HOST.json"],
          description: "manifest-only trusted provider installation document"
        },
        @env_file_option,
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
          key: :output,
          type: :string,
          syntax: ["--output VALUE.json"],
          description: "publish one public profile evaluation value"
        },
        %{
          key: :private_output,
          type: :string,
          syntax: ["--private-output VALUE.json"],
          description: "publish one owner-only private profile evaluation value"
        },
        %{
          key: :format,
          type: :string,
          syntax: ["--format clojure|jsonl"],
          description: "choose human or JSON Lines profile output"
        },
        %{
          key: :preview_chars,
          type: :integer,
          syntax: ["--preview-chars COUNT"],
          description: "REPL structural preview character ceiling"
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
      ]
    },
    viewer: %{
      usage: [
        "ptc viewer PROJECT.json [--port PORT] [--listen ADDRESS] [--env-file FILE]"
      ],
      options: [
        %{
          key: :port,
          type: :string,
          syntax: ["--port PORT"],
          description: "override the project's Viewer port"
        },
        %{
          key: :listen,
          type: :string,
          syntax: ["--listen 127.0.0.1|0.0.0.0"],
          description: "bind address; 0.0.0.0 exposes the Viewer beyond this host"
        },
        @env_file_option,
        @help_option
      ]
    }
  }

  @commands [
    :version,
    :init,
    :docs,
    :validate,
    :run,
    :doctor,
    :models,
    :transcript,
    :repl,
    :viewer
  ]
  @topics [:root | @commands]
  # Commands the shared engine never dispatches: their frontend owns the
  # process for as long as it runs and returns no envelope.
  @frontend_commands [:transcript, :repl, :viewer]

  @type command ::
          :version
          | :init
          | :docs
          | :validate
          | :run
          | :doctor
          | :models
          | :transcript
          | :repl
          | :viewer
  @type topic :: :root | command()
  @type frontend :: :standalone | :mix

  @spec commands() :: [command()]
  def commands, do: @commands

  @spec topics() :: [topic()]
  def topics, do: @topics

  @spec frontend_commands() :: [command()]
  def frontend_commands, do: @frontend_commands

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
