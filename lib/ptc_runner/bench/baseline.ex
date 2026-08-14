defmodule PtcRunner.Bench.Baseline do
  @moduledoc false
  # Shared baseline-file plumbing for the `mix bench.*` tasks.
  #
  # Benchmark portability is metric-specific. Whole-VM heap figures depend on
  # the host architecture and scheduler shape. Child-process reductions are
  # stable across hosts only for the same Elixir/OTP/ERTS, emulator flavor, and
  # word size. Every baseline records full provenance so each owning task can
  # validate the fields relevant to its metric and report the rest.

  @doc "Reads a committed baseline, raising a `Mix.raise` on a missing file."
  @spec read!(Path.t()) :: map()
  def read!(path) do
    case File.read(path) do
      {:ok, json} ->
        Jason.decode!(json)

      {:error, :enoent} ->
        Mix.raise("missing baseline #{path}; run the owning task with --write-baseline")

      {:error, reason} ->
        Mix.raise("could not read baseline #{path}: #{inspect(reason)}")
    end
  end

  @doc "Writes `contents` as pretty JSON, creating the baseline directory."
  @spec write!(Path.t(), map()) :: :ok
  def write!(path, contents) when is_map(contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(contents, pretty: true) <> "\n")
    Mix.shell().info("Wrote #{path}")
  end

  @doc """
  Captures the environment a baseline was measured in.

  Portability depends on the metric. An owning task must validate the fields
  that affect its comparison and may retain the others for diagnostics.
  """
  @spec provenance() :: map()
  def provenance do
    %{
      "commit" => commit(),
      "mix_env" => Mix.env() |> Atom.to_string(),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "erts" => to_string(:erlang.system_info(:version)),
      "architecture" => to_string(:erlang.system_info(:system_architecture)),
      "emu_flavor" => to_string(:erlang.system_info(:emu_flavor)),
      "wordsize_bytes" => :erlang.system_info({:wordsize, :internal}),
      "schedulers_online" => System.schedulers_online(),
      "dirty_cpu_schedulers" => :erlang.system_info(:dirty_cpu_schedulers),
      "logical_processors" => logical_processors()
    }
  end

  @doc "Median of a non-empty list of numbers."
  @spec median([number()]) :: number()
  def median([_ | _] = values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp commit do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  rescue
    # `git` need not exist wherever a baseline is regenerated.
    ErlangError -> "unknown"
  end

  defp logical_processors do
    case :erlang.system_info(:logical_processors) do
      count when is_integer(count) -> count
      _unknown -> 0
    end
  end
end
