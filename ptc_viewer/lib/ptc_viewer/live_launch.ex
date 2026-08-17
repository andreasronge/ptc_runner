defmodule PtcViewer.LiveLaunch do
  @moduledoc """
  Viewer-triggered run launching (#1444): fixed target, editable input.

  The launch target and adapter are configured by the operator when the Viewer
  starts and are never taken from the browser. The browser edits exactly one
  thing: the input object, which is written to a temp file beside the fixed
  manifest. The host adapter executes the semantic request and receives a
  direct frame sink; PtcViewer remains independent of the host runtime and no
  command subprocess or callback URL is required.
  """

  @output_tail_bytes 2_000
  @mission_name ~r/\A[a-z][a-z0-9._-]{0,127}\z/

  @type request ::
          {:workflow, %{required(:input) => binary()}}
          | {:mission, %{required(:name) => binary(), required(:expression) => binary()}}

  @type spec :: %{
          required(:manifest) => binary(),
          required(:adapter) => (request(), (binary(), map() -> term()) ->
                                   {non_neg_integer(), binary()}),
          optional(:cwd) => binary(),
          optional(:label) => binary()
        }

  @doc "Validates an operator-supplied launch spec at Viewer startup."
  @spec validate(term()) :: :ok | {:error, :invalid_launch_config}
  def validate(nil), do: :ok

  def validate(%{manifest: manifest, adapter: adapter} = spec) when is_binary(manifest) do
    cwd = Map.get(spec, :cwd, File.cwd!())
    label = Map.get(spec, :label)

    valid? =
      is_function(adapter, 2) and is_binary(cwd) and File.dir?(cwd) and
        (is_nil(label) or is_binary(label)) and File.regular?(manifest_path(spec))

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
  Builds the zero-arity workflow function for `LiveStore.begin_launch/2`.

  The returned function invokes the fixed host adapter only after the
  single-flight launch gate accepts it.
  """
  @spec prepare(spec(), map(), pid()) ::
          {:ok, (-> {integer(), binary()})} | {:error, :invalid_input}
  def prepare(spec, input, store) when is_map(spec) and is_map(input) and is_pid(store) do
    with {:ok, input_json} <- Jason.encode(input) do
      {:ok, fn -> run_workflow(spec, input_json, store) end}
    else
      {:error, _reason} -> {:error, :invalid_input}
    end
  end

  def prepare(_spec, _input, _store), do: {:error, :invalid_input}

  @doc """
  Builds the run function for a one-shot session in one manifest mission.

  Mission sessions do not execute through `Runner`, so no live frames arrive:
  the exit code and output tail are the whole result surface until reporter
  coverage reaches REPL sessions.
  """
  @spec prepare_mission(spec(), binary(), binary(), pid()) ::
          {:ok, (-> {integer(), binary()})} | {:error, :invalid_mission}
  def prepare_mission(spec, mission, expression, store) when is_map(spec) and is_pid(store) do
    if valid_mission?(mission) and valid_expression?(expression) do
      {:ok,
       fn ->
         invoke_adapter(
           spec,
           {:mission, %{name: mission, expression: expression}},
           store
         )
       end}
    else
      {:error, :invalid_mission}
    end
  end

  def prepare_mission(_spec, _mission, _expression, _store), do: {:error, :invalid_mission}

  defp valid_mission?(mission),
    do: is_binary(mission) and Regex.match?(@mission_name, mission)

  defp valid_expression?(expression),
    do: is_binary(expression) and String.trim(expression) != ""

  defp run_workflow(spec, input_json, store) do
    case write_input(spec, input_json) do
      {:ok, input_file} ->
        try do
          invoke_adapter(spec, {:workflow, %{input: input_file.name}}, store)
        after
          _ = File.rm(input_file.path)
        end

      {:error, :invalid_input} ->
        {1, "viewer launch failed: input file unavailable"}
    end
  end

  # `--input` is a logical name resolved inside the manifest's confined
  # application directory. Creation happens only after the single-flight gate
  # accepts the launch; an exclusive random name cannot replace a project file
  # or collide with another request.
  defp write_input(spec, input_json, attempts \\ 3)

  defp write_input(_spec, _input_json, 0), do: {:error, :invalid_input}

  defp write_input(spec, input_json, attempts) do
    name = temporary_input_name()
    path = spec |> manifest_path() |> Path.dirname() |> Path.join(name)

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result =
          try do
            :ok = IO.binwrite(file, input_json)
            :ok
          rescue
            _exception -> :error
          after
            _ = File.close(file)
          end

        if result == :ok do
          {:ok, %{name: name, path: path}}
        else
          _ = File.rm(path)
          {:error, :invalid_input}
        end

      {:error, :eexist} ->
        write_input(spec, input_json, attempts - 1)

      {:error, _reason} ->
        {:error, :invalid_input}
    end
  end

  @doc false
  def temporary_input_name,
    do: "ptc-viewer-input-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}.json"

  defp invoke_adapter(spec, request, store) do
    case spec.adapter.(request, frame_sink(store)) do
      {code, output} when is_integer(code) and code >= 0 and is_binary(output) ->
        {code, output_tail(output)}

      _invalid ->
        {1, "viewer launch failed: invalid adapter result"}
    end
  rescue
    exception -> {1, "viewer launch failed: " <> Exception.message(exception)}
  catch
    _kind, reason -> {1, "viewer launch failed: " <> inspect(reason)}
  end

  defp frame_sink(store) do
    fn run_id, frame ->
      with true <- is_binary(run_id) and is_map(frame),
           {:ok, encoded} <- Jason.encode(frame),
           {:ok, decoded} <- Jason.decode(encoded) do
        PtcViewer.LiveStore.put_frame(store, run_id, decoded)
      else
        _invalid -> {:error, :invalid_frame}
      end
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
