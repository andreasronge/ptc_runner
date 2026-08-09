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

    # Requesting both destinations is rejected before input/output mode
    # authorization, not after: it is a more fundamental error than a mode
    # mismatch, and checking modes first masks the conflict behind whichever
    # destination's rules happen to run first. Deliberately a narrow, separate
    # guard rather than reordering the whole destination check - the
    # single-destination paths keep their existing "which mode is wrong"
    # ordering. It is a named function so a per-command declaration can point
    # at one mutual-exclusion rule instead of restating it.
    with true <- is_boolean(unattended),
         :ok <- reject_destination_conflict(private_terminal, unattended),
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

  defp reject_destination_conflict(true, true), do: {:error, :private_destination_conflict}
  defp reject_destination_conflict(_terminal, _unattended), do: :ok

  # An unattended private destination admits only the non-interactive input
  # modes and the machine-readable output format that log-analysis-v2 already
  # has. `:interactive` is deliberately absent: it means waiting on a human at
  # a keyboard, which is the one thing "unattended" rules out. Admitting it let
  # `--private-unattended --format jsonl` with no -e/--load/script/stdin fall
  # through to the interactive REPL loop, interleaving its human prompt banner
  # into a stream the caller relies on being valid JSONL (#1220).
  # The attached-terminal default is unchanged, so nothing that worked before
  # behaves differently.
  @unattended_input_modes [:eval, :load, :script, :stdin]
  @unattended_output_formats [:clojure, :jsonl]

  @doc """
  Returns the input modes and output formats reachable for one invocation.

  A profile's declared `input_modes`/`output_formats` describe its attended
  path only. An unattended private destination widens both, so a frontend
  deciding whether a combination is reachable must ask here rather than read
  the static declaration. Reading the static list is precisely what let #1220
  through: the "jsonl requires input" guard consulted
  `frontend.output_formats`, which does not contain `:jsonl` for
  `inspection-analysis-v2`, so the guard skipped the very call that needed it.
  """
  @spec reachable_frontend(recipe(), boolean()) :: %{
          input_modes: [atom()],
          output_formats: [atom()]
        }
  def reachable_frontend(recipe, private_unattended \\ false) when is_atom(recipe) do
    recipe.frontend() |> reachable(private_unattended)
  end

  defp reachable(%{private_terminal: :required} = _frontend, true),
    do: %{input_modes: @unattended_input_modes, output_formats: @unattended_output_formats}

  defp reachable(frontend, _unattended),
    do: %{input_modes: frontend.input_modes, output_formats: frontend.output_formats}

  defp authorize_input(frontend, input_mode, unattended) do
    allowed = reachable(frontend, unattended).input_modes
    if input_mode in allowed, do: :ok, else: {:error, :unsupported_profile_input}
  end

  defp authorize_output(frontend, output_format, unattended) do
    allowed = reachable(frontend, unattended).output_formats
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
      else:
        description
        |> Map.put("private_terminal", frontend_value(frontend.private_terminal))
        |> put_unattended_surface(frontend)
  end

  # The declared modes above describe the attended path. A profile requiring a
  # private destination reaches a wider surface under `private_unattended`, so
  # the description says so rather than reporting the attended path as if it
  # were the whole contract - a self-describing profile that omits half its
  # reachable surface is the drift this description exists to prevent.
  defp put_unattended_surface(description, %{private_terminal: :required} = frontend) do
    reachable = reachable(frontend, true)

    Map.put(description, "private_unattended", %{
      "input_modes" => Enum.map(reachable.input_modes, &Atom.to_string/1),
      "output_formats" => Enum.map(reachable.output_formats, &Atom.to_string/1)
    })
  end

  defp put_unattended_surface(description, _frontend), do: description

  defp frontend_value(:repeated_eval_only), do: "repeated-eval-only"
  defp frontend_value(value) when is_atom(value), do: Atom.to_string(value)
end
