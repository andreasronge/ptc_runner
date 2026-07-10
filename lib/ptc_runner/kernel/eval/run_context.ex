defmodule PtcRunner.Kernel.Eval.RunContext do
  @moduledoc false

  @enforce_keys [:initial_snapshot, :manifest_path, :snapshot_fn]
  defstruct [:initial_snapshot, :manifest_path, :snapshot_fn]

  @type snapshot :: %{commit: String.t(), clean: boolean()}
  @type t :: %__MODULE__{
          initial_snapshot: snapshot(),
          manifest_path: String.t(),
          snapshot_fn: (-> snapshot())
        }

  @spec start!(String.t(), map(), keyword()) :: t()
  def start!(report_path, metadata, opts) do
    snapshot_fn = Keyword.get(opts, :repository_snapshot_fn, &repository_snapshot/0)
    initial = snapshot_fn.()
    manifest_path = report_path <> ".attempt.json"

    ensure_absent!([report_path, Path.rootname(report_path) <> ".json", manifest_path])
    File.mkdir_p!(Path.dirname(manifest_path))

    manifest =
      metadata
      |> Map.merge(%{state: "running", initial_snapshot: initial})

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true) <> "\n", [:exclusive])

    %__MODULE__{
      initial_snapshot: initial,
      manifest_path: manifest_path,
      snapshot_fn: snapshot_fn
    }
  end

  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = context) do
    current = context.snapshot_fn.()

    if eligible_snapshot?(context.initial_snapshot) and current == context.initial_snapshot do
      :ok
    else
      {:error, "repository_state_changed"}
    end
  end

  @spec finish!(t(), String.t(), map()) :: snapshot()
  def finish!(%__MODULE__{} = context, state, metadata) do
    final = context.snapshot_fn.()

    manifest =
      metadata
      |> Map.merge(%{
        state: state,
        initial_snapshot: context.initial_snapshot,
        final_snapshot: final
      })

    temporary = context.manifest_path <> ".tmp"
    File.write!(temporary, Jason.encode!(manifest, pretty: true) <> "\n", [:exclusive])
    File.rename!(temporary, context.manifest_path)
    final
  end

  @spec eligible?(t(), snapshot()) :: boolean()
  def eligible?(%__MODULE__{} = context, final) do
    eligible_snapshot?(context.initial_snapshot) and final == context.initial_snapshot
  end

  defp ensure_absent!(paths) do
    case Enum.find(paths, &File.exists?/1) do
      nil -> :ok
      path -> raise ArgumentError, "canonical experiment artifact already exists: #{path}"
    end
  end

  defp eligible_snapshot?(%{commit: commit, clean: true}) do
    is_binary(commit) and Regex.match?(~r/\A[0-9a-f]{40}\z/, commit)
  end

  defp eligible_snapshot?(_snapshot), do: false

  defp repository_snapshot do
    commit =
      case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: false) do
        {hash, 0} -> String.trim(hash)
        _ -> "unknown"
      end

    clean =
      case System.cmd("git", ["status", "--porcelain=v1"], stderr_to_stdout: false) do
        {"", 0} -> true
        {_output, _status} -> false
      end

    %{commit: commit, clean: clean}
  end
end
