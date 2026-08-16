defmodule PtcViewer.LiveLaunch do
  @moduledoc """
  Viewer-triggered run launching (#1444): fixed target, editable input.

  The launch target — manifest path, extra CLI arguments, working directory —
  is configured by the operator when the Viewer starts and is never taken
  from the browser. The browser edits exactly one thing: the input object,
  which is written to a temp file and passed via `--input`. The run itself is
  an ordinary `mix ptc run` child process pointed back at this Viewer with
  `PTC_VIEWER_URL`, so launched runs report through the same live channel as
  CLI-launched ones.
  """

  @output_tail_bytes 2_000

  @type spec :: %{
          required(:manifest) => binary(),
          optional(:args) => [binary()],
          optional(:cwd) => binary(),
          optional(:label) => binary()
        }

  @doc "Validates an operator-supplied launch spec at Viewer startup."
  @spec validate(term()) :: :ok | {:error, :invalid_launch_config}
  def validate(nil), do: :ok

  def validate(%{manifest: manifest} = spec) when is_binary(manifest) do
    args = Map.get(spec, :args, [])
    cwd = Map.get(spec, :cwd, File.cwd!())
    label = Map.get(spec, :label)

    valid? =
      is_list(args) and Enum.all?(args, &is_binary/1) and
        is_binary(cwd) and File.dir?(cwd) and
        (is_nil(label) or is_binary(label)) and
        File.regular?(manifest_path(spec))

    if valid?, do: :ok, else: {:error, :invalid_launch_config}
  end

  def validate(_spec), do: {:error, :invalid_launch_config}

  @doc "Static description plus the manifest's current input object, for the UI."
  @spec describe(spec(), map()) :: map()
  def describe(spec, launch_status) when is_map(spec) and is_map(launch_status) do
    %{
      "enabled" => true,
      "manifest" => spec.manifest,
      "label" => Map.get(spec, :label),
      "input" => manifest_input(spec),
      "launch" => launch_status
    }
  end

  @doc """
  Builds the zero-arity run function for `LiveStore.begin_launch/2`.

  Returns `{:error, :launch_not_configured}` when no usable Viewer port is
  known (e.g. port 0 in tests).
  """
  @spec prepare(spec(), map(), integer()) ::
          {:ok, (-> {integer(), binary()})} | {:error, :launch_not_configured | :invalid_input}
  def prepare(_spec, _input, port) when not is_integer(port) or port <= 0,
    do: {:error, :launch_not_configured}

  def prepare(spec, input, port) when is_map(spec) and is_map(input) do
    cwd = Map.get(spec, :cwd, File.cwd!())

    with {:ok, input_file} <- write_input(spec, input) do
      label = Map.get(spec, :label) || Path.basename(spec.manifest)

      args =
        ["ptc", "run", spec.manifest] ++
          Map.get(spec, :args, []) ++ ["--input", input_file.name]

      env = [
        {"PTC_VIEWER_URL", "http://127.0.0.1:#{port}"},
        {"PTC_VIEWER_LABEL", label}
      ]

      {:ok,
       fn ->
         {output, code} = System.cmd("mix", args, cd: cwd, env: env, stderr_to_stdout: true)
         _ = File.rm(input_file.path)
         {code, output_tail(output)}
       end}
    end
  end

  def prepare(_spec, _input, _port), do: {:error, :invalid_input}

  # `--input` is a logical name resolved inside the manifest's confined
  # application directory, so the edited input is written beside the manifest
  # under a fixed name (single-flight gate prevents concurrent launches) and
  # removed once the run exits.
  defp write_input(spec, input) do
    name = "live-input.json"
    path = spec |> manifest_path() |> Path.dirname() |> Path.join(name)

    case Jason.encode(input) do
      {:ok, json} ->
        case File.write(path, json) do
          :ok -> {:ok, %{name: name, path: path}}
          {:error, _reason} -> {:error, :invalid_input}
        end

      {:error, _reason} ->
        {:error, :invalid_input}
    end
  end

  defp manifest_input(spec) do
    with {:ok, raw} <- File.read(manifest_path(spec)),
         {:ok, %{"input" => %{"value" => value}}} when is_map(value) <- Jason.decode(raw) do
      value
    else
      _other -> %{}
    end
  end

  defp manifest_path(spec) do
    cwd = Map.get(spec, :cwd, File.cwd!())
    Path.expand(spec.manifest, cwd)
  end

  defp output_tail(output) when byte_size(output) <= @output_tail_bytes, do: output

  defp output_tail(output),
    do: binary_part(output, byte_size(output) - @output_tail_bytes, @output_tail_bytes)
end
