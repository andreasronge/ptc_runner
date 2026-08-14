defmodule PtcRunner.TestSupport.GuideExamples do
  @moduledoc false

  alias __MODULE__, as: GuideExamples

  defstruct [:command, :expected, :id, :line, :requires]

  @annotation ~r/<!-- ptc-guide-e2e: (?<options>[^>]+) -->/
  @example ~r/<!-- ptc-guide-e2e: (?<options>[^>]+) -->\s*```console\n(?<command>.*?)\n```\s*```json\n(?<expected>.*?)\n```/s
  @id ~r/^[a-z][a-z0-9-]*$/
  @environment_variable ~r/^[A-Z][A-Z0-9_]*$/

  @type t :: %__MODULE__{
          command: String.t(),
          expected: term(),
          id: String.t(),
          line: pos_integer(),
          requires: String.t() | nil
        }

  defmacro test_examples(path) do
    root = File.cwd!()
    examples = path |> Path.expand(root) |> parse_file!()

    tests =
      Enum.map(examples, fn example ->
        tag =
          if example.requires do
            quote do
              @tag :scheduled_e2e
              @tag requires_env: unquote(example.requires)
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
          stdout: String.t()
        }
  def run(example, root) do
    temporary =
      Path.join(System.tmp_dir!(), "ptc-guide-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(temporary)
    File.chmod!(temporary, 0o700)

    try do
      stdout_path = Path.join(temporary, "stdout")
      stderr_path = Path.join(temporary, "stderr")
      environment = command_environment(example, temporary)

      {_output, status} =
        System.cmd(
          System.find_executable("bash") || raise("bash is required for guide examples"),
          [
            "-c",
            ~S(bash -euo pipefail -c "$1" >"$2" 2>"$3"),
            "ptc-guide-e2e",
            example.command,
            stdout_path,
            stderr_path
          ],
          cd: root,
          env: [{"MIX_ENV", "test"}, {"MIX_QUIET", "1"} | environment]
        )

      %{
        status: status,
        stdout: File.read!(stdout_path),
        stderr: File.read!(stderr_path)
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

  defp build_example!(content, match, path) do
    [{start, _length}, options, command, expected] = match
    options = capture(content, options) |> parse_options!(path)

    %__MODULE__{
      id: Map.fetch!(options, "id"),
      requires: Map.get(options, "requires"),
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

    if map_size(parsed) != length(option_list) or Map.keys(parsed) -- ~w(id requires) != [] or
         not Map.has_key?(parsed, "id") or
         not Regex.match?(@id, parsed["id"]) or
         not valid_requirement?(parsed["requires"]) do
      raise ArgumentError, "invalid ptc-guide-e2e options in #{path}: #{options}"
    end

    parsed
  end

  defp valid_requirement?(nil), do: true
  defp valid_requirement?(name), do: Regex.match?(@environment_variable, name)

  defp line_number(prefix) do
    prefix
    |> :binary.matches("\n")
    |> length()
    |> Kernel.+(1)
  end

  defp command_environment(%{requires: nil}, _temporary), do: []

  defp command_environment(%{requires: variable}, temporary) do
    value = System.fetch_env!(variable)

    if String.contains?(value, ["\n", "\r"]) do
      raise ArgumentError, "#{variable} cannot contain a newline"
    end

    env_file = Path.join(temporary, ".env")
    File.write!(env_file, "#{variable}=#{value}\n")
    File.chmod!(env_file, 0o600)
    [{"PTC_ENV_FILE", env_file}, {variable, nil}]
  end
end
