defmodule Mix.Tasks.Ptc.Dna do
  @shortdoc "Run ExDNA duplicate-code detection on a chosen Mix project"
  @moduledoc """
  Thin wrapper around `mix ex_dna` that dispatches to the root project or one of
  the sibling Mix projects (`mcp_server`, `ptc_viewer`).

  Each project carries its own `:ex_dna` dev dep, so analysis is scoped to that
  project's `lib/`. This task exists so you do not have to remember to `cd` first.

  ## Usage

      mix ptc.dna                       # root project (lib/)
      mix ptc.dna mcp_server            # mcp_server/lib/
      mix ptc.dna ptc_viewer            # ptc_viewer/lib/
      mix ptc.dna --all                 # all three, sequentially

  Anything after the project selector is forwarded to `mix ex_dna`:

      mix ptc.dna --literal-mode abstract
      mix ptc.dna mcp_server --min-similarity 0.9
      mix ptc.dna --all --min-similarity 0.85

  Advisory only — not wired into `mix precommit`. See ExDNA docs for flags:
  https://hexdocs.pm/ex_dna/
  """

  use Mix.Task

  @projects %{
    "root" => ".",
    "mcp_server" => "mcp_server",
    "ptc_viewer" => "ptc_viewer"
  }

  @impl Mix.Task
  def run(args) do
    {project, ex_dna_args} = parse_args(args)

    case project do
      :all ->
        @projects
        |> Enum.map(fn {name, path} -> run_in(name, path, ex_dna_args) end)
        |> summarize()

      {name, path} ->
        case run_in(name, path, ex_dna_args) do
          :ok -> :ok
          {:error, code} -> exit({:shutdown, code})
        end
    end
  end

  defp parse_args(["--all" | rest]), do: {:all, rest}
  defp parse_args(["--help" | _]), do: print_help_and_halt()
  defp parse_args(["-h" | _]), do: print_help_and_halt()

  defp parse_args([first | rest]) do
    cond do
      Map.has_key?(@projects, first) -> {{first, @projects[first]}, rest}
      String.starts_with?(first, "-") -> {{"root", "."}, [first | rest]}
      true -> Mix.raise("Unknown project #{inspect(first)}. Expected one of: " <> known())
    end
  end

  defp parse_args([]), do: {{"root", "."}, []}

  defp known, do: @projects |> Map.keys() |> Enum.join(", ")

  defp run_in(name, path, args) do
    Mix.shell().info(IO.ANSI.bright() <> "==> ex_dna (#{name})" <> IO.ANSI.reset())

    cmd_args = ["ex_dna" | args]

    {_, exit_code} =
      System.cmd("mix", cmd_args,
        cd: path,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    case exit_code do
      0 -> :ok
      code -> {:error, code}
    end
  end

  defp summarize(results) do
    failures =
      results
      |> Enum.reject(&(&1 == :ok))
      |> Enum.count()

    if failures > 0 do
      Mix.shell().error("\nex_dna reported issues in #{failures} project(s)")
      exit({:shutdown, 1})
    end
  end

  defp print_help_and_halt do
    Mix.shell().info(@moduledoc)
    exit(:normal)
  end
end
