defmodule PtcRunner.Kernel.AnalysisProfileRegistry do
  @moduledoc """
  Closed registry of code-owned analysis-session authority recipes.

  Profile IDs resolve only to modules compiled into PtcRunner. The registry is
  intentionally not configurable: callers may select an ID and supply its
  declared resources, but cannot install a module or widen frontend modes,
  sinks, components, capabilities, limits, or cleanup.
  """

  alias PtcRunner.Kernel.InspectionAnalysisProfile
  alias PtcRunner.Kernel.LogAnalysisProfile

  @profiles %{
    "inspection-analysis-v1" => InspectionAnalysisProfile,
    "log-analysis-v1" => LogAnalysisProfile
  }

  @type recipe :: module()

  @spec ids() :: [binary()]
  def ids, do: @profiles |> Map.keys() |> Enum.sort()

  @spec fetch(binary()) :: {:ok, recipe()} | {:error, :unsupported_analysis_profile}
  def fetch(id) when is_binary(id) do
    case Map.fetch(@profiles, id) do
      {:ok, recipe} -> {:ok, recipe}
      :error -> {:error, :unsupported_analysis_profile}
    end
  end

  def fetch(_id), do: {:error, :unsupported_analysis_profile}

  @spec description(binary()) :: {:ok, map()} | {:error, :unsupported_analysis_profile}
  def description(id) do
    with {:ok, recipe} <- fetch(id) do
      {:ok, Map.put(recipe.description(), "frontend", frontend_description(recipe))}
    end
  end

  @doc false
  @spec authorize_frontend(
          recipe(),
          %{
            required(:input_mode) => atom(),
            required(:output_format) => atom(),
            required(:continue_on_error) => boolean(),
            required(:private_terminal) => boolean(),
            required(:terminal_attached) => boolean()
          }
        ) :: :ok | {:error, atom()}
  def authorize_frontend(
        recipe,
        %{
          input_mode: input_mode,
          output_format: output_format,
          continue_on_error: continue_on_error,
          private_terminal: private_terminal,
          terminal_attached: terminal_attached
        }
      )
      when is_atom(recipe) and is_atom(input_mode) and is_atom(output_format) and
             is_boolean(continue_on_error) and is_boolean(private_terminal) and
             is_boolean(terminal_attached) do
    frontend = recipe.frontend()

    with :ok <- authorize_input(frontend, input_mode),
         :ok <- authorize_output(frontend, output_format),
         :ok <- authorize_continuation(frontend, continue_on_error) do
      authorize_terminal(frontend, private_terminal, terminal_attached)
    end
  end

  def authorize_frontend(_recipe, _context), do: {:error, :invalid_profile_frontend}

  defp authorize_input(frontend, input_mode) do
    if input_mode in frontend.input_modes,
      do: :ok,
      else: {:error, :unsupported_profile_input}
  end

  defp authorize_output(frontend, output_format) do
    if output_format in frontend.output_formats,
      do: :ok,
      else: {:error, :unsupported_profile_output}
  end

  defp authorize_continuation(%{continue_on_error: :forbidden}, true),
    do: {:error, :unsupported_profile_continuation}

  defp authorize_continuation(_frontend, _continue_on_error), do: :ok

  defp authorize_terminal(%{private_terminal: :required}, false, _terminal_attached),
    do: {:error, :private_terminal_required}

  defp authorize_terminal(%{private_terminal: :required}, true, false),
    do: {:error, :interactive_terminal_required}

  defp authorize_terminal(%{private_terminal: :forbidden}, true, _terminal_attached),
    do: {:error, :private_terminal_unsupported}

  defp authorize_terminal(_frontend, _private_terminal, _terminal_attached), do: :ok

  defp frontend_description(recipe) do
    frontend = recipe.frontend()

    description = %{
      "input_modes" => Enum.map(frontend.input_modes, &Atom.to_string/1),
      "output_formats" => Enum.map(frontend.output_formats, &Atom.to_string/1),
      "continue_on_error" => frontend_value(frontend.continue_on_error)
    }

    if recipe.id() == "log-analysis-v1",
      do: description,
      else: Map.put(description, "private_terminal", frontend_value(frontend.private_terminal))
  end

  defp frontend_value(:repeated_eval_only), do: "repeated-eval-only"
  defp frontend_value(value) when is_atom(value), do: Atom.to_string(value)
end
