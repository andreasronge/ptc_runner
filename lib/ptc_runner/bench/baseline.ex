defmodule PtcRunner.Bench.Baseline do
  @moduledoc false
  # Shared baseline-file plumbing for the `mix bench.*` tasks.
  #
  # A committed benchmark number is only readable next to the machine that
  # produced it: heap and reduction figures do not carry across OTP releases,
  # architectures, scheduler counts, or emulator flavors. Every baseline this
  # module writes therefore records its own provenance, and every task that
  # reads one gets the same accessors rather than its own copy.

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

  None of these are portable, so a baseline that omits them cannot be checked
  against anything: an OTP bump, a different word size, or a different
  scheduler count moves the numbers on their own.
  """
  @spec provenance() :: map()
  def provenance do
    %{
      "commit" => commit(),
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
