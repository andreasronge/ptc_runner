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
    "inspection-analysis-v2" => InspectionAnalysisProfile,
    "log-analysis-v2" => LogAnalysisProfile
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
            optional(:private_unattended) => boolean(),
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
        } = context
      )
      when is_atom(recipe) and is_atom(input_mode) and is_atom(output_format) and
             is_boolean(continue_on_error) and is_boolean(private_terminal) and
             is_boolean(terminal_attached) do
    frontend = recipe.frontend()
    unattended = Map.get(context, :private_unattended, false)

    with true <- is_boolean(unattended),
         :ok <- authorize_input(frontend, input_mode, unattended),
         :ok <- authorize_output(frontend, output_format, unattended),
         :ok <- authorize_continuation(frontend, continue_on_error) do
      authorize_private_destination(frontend, private_terminal, unattended, terminal_attached)
    else
      false -> {:error, :invalid_profile_frontend}
      {:error, _reason} = error -> error
    end
  end

  def authorize_frontend(_recipe, _context), do: {:error, :invalid_profile_frontend}

  # An unattended private destination admits the non-interactive input modes
  # and the machine-readable output format that log-analysis-v2 already has.
  # The attached-terminal default is unchanged, so nothing that worked before
  # behaves differently.
  @unattended_input_modes [:interactive, :eval, :load, :script, :stdin]
  @unattended_output_formats [:clojure, :jsonl]

  defp authorize_input(frontend, input_mode, unattended) do
    allowed =
      if unattended and frontend.private_terminal == :required,
        do: @unattended_input_modes,
        else: frontend.input_modes

    if input_mode in allowed, do: :ok, else: {:error, :unsupported_profile_input}
  end

  defp authorize_output(frontend, output_format, unattended) do
    allowed =
      if unattended and frontend.private_terminal == :required,
        do: @unattended_output_formats,
        else: frontend.output_formats

    if output_format in allowed, do: :ok, else: {:error, :unsupported_profile_output}
  end

  defp authorize_continuation(%{continue_on_error: :forbidden}, true),
    do: {:error, :unsupported_profile_continuation}

  defp authorize_continuation(_frontend, _continue_on_error), do: :ok

  defp authorize_private_destination(_frontend, true, true, _attached),
    do: {:error, :private_destination_conflict}

  defp authorize_private_destination(%{private_terminal: :required}, false, false, _attached),
    do: {:error, :private_terminal_required}

  defp authorize_private_destination(%{private_terminal: :required}, true, false, false),
    do: {:error, :interactive_terminal_required}

  defp authorize_private_destination(
         %{private_terminal: :forbidden},
         terminal,
         unattended,
         _attached
       )
       when terminal or unattended,
       do: {:error, :private_terminal_unsupported}

  defp authorize_private_destination(_frontend, _terminal, _unattended, _attached), do: :ok

  defp frontend_description(recipe) do
    frontend = recipe.frontend()

    description = %{
      "input_modes" => Enum.map(frontend.input_modes, &Atom.to_string/1),
      "output_formats" => Enum.map(frontend.output_formats, &Atom.to_string/1),
      "continue_on_error" => frontend_value(frontend.continue_on_error)
    }

    if frontend.private_terminal == :forbidden,
      do: description,
      else: Map.put(description, "private_terminal", frontend_value(frontend.private_terminal))
  end

  defp frontend_value(:repeated_eval_only), do: "repeated-eval-only"
  defp frontend_value(value) when is_atom(value), do: Atom.to_string(value)
end
