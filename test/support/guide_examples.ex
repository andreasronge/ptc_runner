defmodule PtcRunner.TestSupport.GuideExamples do
  @moduledoc false

  alias __MODULE__, as: GuideExamples
  alias PtcRunner.Kernel.ProjectConfig

  defstruct [
    :assertion,
    :command,
    :expected,
    :frontend,
    :id,
    :line,
    :project,
    :requires,
    :scratch
  ]

  @annotation ~r/<!-- ptc-guide-e2e: (?<options>[^>]+) -->/
  @example ~r/<!-- ptc-guide-e2e: (?<options>[^>]+) -->\s*```console\n(?<command>.*?)\n```\s*```json\n(?<expected>.*?)\n```/s
  @id ~r/^[a-z][a-z0-9-]*$/
  @environment_variable ~r/^[A-Z][A-Z0-9_]*$/
  @scratch_path ~r/^[a-z0-9][a-z0-9._-]{0,127}(?:\/[a-z0-9][a-z0-9._-]{0,127}){0,7}$/
  @assertions ~w(two-turn-agent)
  @temporary_directory_attempts 10

  @type t :: %__MODULE__{
          command: String.t(),
          expected: term(),
          frontend: String.t() | nil,
          id: String.t(),
          line: pos_integer(),
          project: String.t() | nil,
          requires: String.t() | nil,
          assertion: String.t() | nil,
          scratch: String.t() | nil
        }

  defmacro test_registered_examples(registry_path) do
    root = File.cwd!()

    examples =
      registry_path
      |> parse_registry!(root)
      |> Enum.flat_map(&parse_file!/1)

    if examples == [] do
      raise ArgumentError, "no ptc-guide-e2e examples registered in #{registry_path}"
    end

    ids = Enum.map(examples, & &1.id)

    if length(ids) != MapSet.size(MapSet.new(ids)) do
      raise ArgumentError, "ptc-guide-e2e ids must be unique in #{registry_path}"
    end

    build_tests(examples, root)
  end

  @doc false
  @spec parse_registry!(Path.t(), Path.t()) :: [Path.t()]
  def parse_registry!(registry_path, root) do
    registry_path
    |> Path.expand(root)
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {raw_entry, line}, entries ->
      entry = String.trim(raw_entry)

      cond do
        entry == "" or String.starts_with?(entry, "#") ->
          entries

        raw_entry != entry or not canonical_registry_entry?(entry) ->
          raise ArgumentError,
                "executable guide path at #{registry_path}:#{line} must be canonical " <>
                  "and repository-relative: #{inspect(raw_entry)}"

        true ->
          [Path.expand(entry, root) | entries]
      end
    end)
    |> Enum.reverse()
  end

  defp build_tests(examples, root) do
    tests =
      Enum.map(examples, fn example ->
        tag =
          if example.requires do
            skip =
              if requirement_available?(example.requires, root) do
                nil
              else
                quote do
                  @tag skip: unquote("#{example.requires} is not configured")
                end
              end

            quote do
              @tag :scheduled_e2e
              @tag requires_env: unquote(example.requires)
              unquote(skip)
            end
          end

        quote do
          unquote(tag)

          test unquote("guide example: #{example.id}") do
            result =
              GuideExamples.run(
                unquote(Macro.escape(example)),
                unquote(root)
              )

            assert result.status == 0,
                   "guide command failed at line #{unquote(example.line)}:\n#{result.stderr}"

            assert result.stderr == "",
                   "guide command wrote to stderr at line #{unquote(example.line)}:\n#{result.stderr}"

            assert GuideExamples.last_json!(result.stdout) ==
                     unquote(Macro.escape(example.expected))

            assert GuideExamples.verify_assertion(
                     unquote(Macro.escape(example)),
                     result.envelope
                   ) == :ok
          end
        end
      end)

    quote do
      (unquote_splicing(tests))
    end
  end

  @spec parse_file!(Path.t()) :: [t()]
  def parse_file!(path) do
    content = File.read!(path)
    marker_count = @annotation |> Regex.scan(content) |> length()
    matches = Regex.scan(@example, content, return: :index)

    if marker_count != length(matches) do
      raise ArgumentError,
            "every ptc-guide-e2e annotation in #{path} must immediately precede " <>
              "a console block and its expected JSON block"
    end

    examples = Enum.map(matches, &build_example!(content, &1, path))
    ids = Enum.map(examples, & &1.id)

    if examples == [] do
      raise ArgumentError, "no ptc-guide-e2e examples found in #{path}"
    end

    if length(ids) != MapSet.size(MapSet.new(ids)) do
      raise ArgumentError, "ptc-guide-e2e ids must be unique in #{path}"
    end

    examples
  end

  @spec run(t(), Path.t()) :: %{
          status: non_neg_integer(),
          stderr: String.t(),
          stdout: String.t(),
          envelope: map() | nil
        }
  def run(example, root) do
    temporary = temporary_directory!()
    File.chmod!(temporary, 0o700)

    try do
      stdout_path = Path.join(temporary, "stdout")
      stderr_path = Path.join(temporary, "stderr")
      {command, project_path} = isolate_project(example, root, temporary)
      command = isolate_scratch(command, example, temporary)
      command = select_frontend(command, example)
      environment = command_environment(example, temporary, project_path)

      {_output, status} =
        System.cmd(
          System.find_executable("bash") || raise("bash is required for guide examples"),
          [
            "-c",
            ~S(bash -euo pipefail -c "$1" >"$2" 2>"$3"),
            "ptc-guide-e2e",
            command,
            stdout_path,
            stderr_path
          ],
          cd: root,
          env: [{"MIX_ENV", "test"}, {"MIX_QUIET", "1"} | environment]
        )

      %{
        status: status,
        stdout: File.read!(stdout_path),
        stderr: File.read!(stderr_path),
        envelope: read_envelope(example, temporary, project_path)
      }
    after
      File.rm_rf!(temporary)
    end
  end

  @spec last_json!(String.t()) :: term()
  def last_json!(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> List.last()
    |> Jason.decode!()
  end

  @spec verify_assertion(t(), map() | nil) :: :ok | {:error, String.t()}
  def verify_assertion(%{assertion: nil}, nil), do: :ok

  def verify_assertion(%{assertion: "two-turn-agent"}, envelope) do
    case envelope do
      %{
        "status" => "ok",
        "execution" => %{
          "usage" => %{
            "subordinate_evaluations" => 2,
            "capability_calls" => %{"workflow/llm-request" => 2}
          },
          "evaluation_memory" => %{"defined_count" => 1, "history_count" => 1}
        }
      } ->
        :ok

      _unexpected ->
        {:error, "expected a two-turn agent command envelope, got: #{inspect(envelope)}"}
    end
  end

  defp build_example!(content, match, path) do
    [{start, _length}, options, command, expected] = match
    options = capture(content, options) |> parse_options!(path)

    %__MODULE__{
      id: Map.fetch!(options, "id"),
      frontend: Map.get(options, "frontend"),
      project: Map.get(options, "project"),
      requires: Map.get(options, "requires"),
      assertion: Map.get(options, "assert"),
      scratch: Map.get(options, "scratch"),
      command: capture(content, command),
      expected: content |> capture(expected) |> Jason.decode!(),
      line: content |> binary_part(0, start) |> line_number()
    }
  end

  defp capture(content, {start, length}), do: binary_part(content, start, length)

  defp parse_options!(options, path) do
    option_list = String.split(options)

    parsed =
      Map.new(option_list, fn option ->
        case String.split(option, "=", parts: 2) do
          [key, value] when value != "" -> {key, value}
          _invalid -> raise ArgumentError, "invalid ptc-guide-e2e option in #{path}: #{option}"
        end
      end)

    if map_size(parsed) != length(option_list) or
         Map.keys(parsed) -- ~w(assert frontend id project requires scratch) != [] or
         not Map.has_key?(parsed, "id") or
         not Regex.match?(@id, parsed["id"]) or
         not valid_frontend?(parsed["frontend"]) or
         not valid_project?(parsed["project"]) or
         not valid_requirement?(parsed["requires"]) or
         not valid_scratch?(parsed["scratch"]) or
         not valid_assertion?(parsed["assert"]) do
      raise ArgumentError, "invalid ptc-guide-e2e options in #{path}: #{options}"
    end

    parsed
  end

  defp valid_requirement?(nil), do: true
  defp valid_requirement?(name), do: Regex.match?(@environment_variable, name)

  defp valid_scratch?(nil), do: true
  defp valid_scratch?(path), do: Regex.match?(@scratch_path, path)

  defp valid_project?(nil), do: true

  defp valid_project?(path),
    do: canonical_registry_entry?(path) and String.ends_with?(path, ".json")

  defp valid_frontend?(nil), do: true
  defp valid_frontend?("mix"), do: true
  defp valid_frontend?(_frontend), do: false

  defp valid_assertion?(nil), do: true
  defp valid_assertion?(name), do: name in @assertions

  defp requirement_available?(variable, root) do
    configured_value?(System.get_env(variable)) or
      dotenv_defines?(System.get_env("PTC_ENV_FILE") || Path.join(root, ".env"), variable)
  end

  defp dotenv_defines?(path, variable) do
    case File.read(path) do
      {:ok, contents} ->
        Enum.any?(String.split(contents, "\n"), fn line ->
          case String.split(String.trim(line), "=", parts: 2) do
            [^variable, value] -> configured_value?(String.trim(value, " \t\"'"))
            _other -> false
          end
        end)

      {:error, _reason} ->
        false
    end
  end

  defp configured_value?(value), do: is_binary(value) and value != ""

  defp canonical_registry_entry?(entry) do
    parts = Path.split(entry)

    Path.type(entry) == :relative and
      entry == Path.join(parts) and
      not String.contains?(entry, "\\") and
      Enum.all?(parts, &(&1 not in ["", ".", ".."]))
  end

  defp line_number(prefix) do
    prefix
    |> :binary.matches("\n")
    |> length()
    |> Kernel.+(1)
  end

  defp command_environment(example, temporary, project_path) do
    credential_environment(example, temporary, project_path) ++
      assertion_environment(example, temporary, project_path)
  end

  defp credential_environment(%{requires: nil}, _temporary, _project_path), do: []

  defp credential_environment(%{requires: variable}, temporary, nil) do
    value = System.fetch_env!(variable)

    if String.contains?(value, ["\n", "\r"]) do
      raise ArgumentError, "#{variable} cannot contain a newline"
    end

    env_file = Path.join(temporary, ".env")
    File.write!(env_file, "#{variable}=#{value}\n")
    File.chmod!(env_file, 0o600)
    [{"PTC_ENV_FILE", env_file}, {variable, nil}]
  end

  defp credential_environment(%{requires: variable}, _temporary, project_path) do
    value = System.fetch_env!(variable)
    project = load_project!(project_path)

    env_file =
      project.env_file ||
        raise ArgumentError, "project guide example #{project_path} has no environment file"

    File.write!(env_file, "#{variable}=#{value}\n")
    File.chmod!(env_file, 0o600)
    [{variable, nil}]
  end

  defp assertion_environment(%{assertion: nil}, _temporary, _project_path), do: []

  defp assertion_environment(%{assertion: _assertion}, temporary, nil) do
    [{"PTC_ENVELOPE_FILE", Path.join(temporary, "command-envelope.json")}]
  end

  defp assertion_environment(%{assertion: _assertion}, _temporary, _project_path), do: []

  defp read_envelope(%{assertion: nil}, _temporary, _project_path), do: nil

  defp read_envelope(%{assertion: _assertion}, temporary, nil) do
    path = Path.join(temporary, "command-envelope.json")

    case File.read(path) do
      {:ok, contents} -> Jason.decode!(contents)
      {:error, :enoent} -> nil
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  defp read_envelope(%{assertion: _assertion}, _temporary, project_path) do
    project = load_project!(project_path)

    case Path.wildcard(Path.join([project.artifact_root, "envelopes", "*.json"])) do
      [path] -> Jason.decode!(File.read!(path))
      [] -> nil
      paths -> raise ArgumentError, "expected one project envelope, found #{length(paths)}"
    end
  end

  defp isolate_project(%{project: nil} = example, _root, _temporary),
    do: {example.command, nil}

  defp isolate_project(%{project: relative_path} = example, root, temporary) do
    source = Path.expand(relative_path, root)

    if not File.regular?(source) do
      raise ArgumentError, "project guide example does not exist: #{relative_path}"
    end

    destination = Path.join(temporary, "project")

    case File.cp_r(Path.dirname(source), destination) do
      {:ok, _paths} -> :ok
      {:error, reason, path} -> raise File.Error, reason: reason, action: "copy", path: path
    end

    project_path = Path.join(destination, Path.basename(source))
    project = load_project!(project_path)
    if project.artifact_root, do: File.rm_rf!(project.artifact_root)

    command = replace_project_argument!(example.command, relative_path, project_path)
    {command, project_path}
  end

  defp replace_project_argument!(command, relative_path, project_path) do
    case :binary.matches(command, relative_path) do
      [_one] ->
        String.replace(command, relative_path, shell_quote(project_path))

      _other ->
        raise ArgumentError,
              "project guide command must contain its annotated project path exactly once"
    end
  end

  defp isolate_scratch(command, %{scratch: nil}, _temporary), do: command

  defp isolate_scratch(command, %{scratch: relative_path}, temporary) do
    case :binary.matches(command, relative_path) do
      [] ->
        raise ArgumentError,
              "guide command must contain its annotated scratch path at least once"

      _matches ->
        String.replace(command, relative_path, shell_quote(Path.join(temporary, relative_path)))
    end
  end

  defp select_frontend(command, %{frontend: nil}), do: command

  defp select_frontend(command, %{frontend: "mix"}) do
    Regex.replace(~r/^ptc(?=\s)/m, command, "mix ptc")
  end

  defp shell_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp load_project!(path) do
    case ProjectConfig.load(path) do
      {:ok, project} -> project
      {:error, reason} -> raise ArgumentError, "invalid project guide example: #{inspect(reason)}"
    end
  end

  defp temporary_directory! do
    create_temporary_directory!(@temporary_directory_attempts)
  end

  defp create_temporary_directory!(0) do
    raise File.Error,
      reason: :eexist,
      action: "create exclusive guide-example temporary directory",
      path: System.tmp_dir!()
  end

  defp create_temporary_directory!(attempts_left) do
    suffix = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    path = Path.join(System.tmp_dir!(), "ptc-guide-#{suffix}")

    case File.mkdir(path) do
      :ok -> path
      {:error, :eexist} -> create_temporary_directory!(attempts_left - 1)
      {:error, reason} -> raise File.Error, reason: reason, action: "create directory", path: path
    end
  end
end
