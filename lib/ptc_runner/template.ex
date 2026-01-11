defmodule PtcRunner.Template do
  @moduledoc """
  Represents a template with extracted placeholders.

  A `Template` struct contains:
  - `template`: The raw template string with `{{placeholder}}` syntax
  - `placeholders`: List of extracted placeholders with their paths

  ## Examples

      iex> PtcRunner.Template.__struct__()
      %PtcRunner.Template{template: nil, placeholders: nil}

  Templates are typically created using the `~T` sigil:

      import PtcRunner.SubAgent.Sigils
      ~T"Hello {{name}}"

  Note: The `~T` sigil shadows Elixir's built-in Time sigil within modules
  that import `PtcRunner.SubAgent.Sigils`. This is intentional and safe
  because the two sigils are used in different contexts (template strings
  vs time literals with square brackets like `~T[00:00:00]`).

  See `PtcRunner.SubAgent.MissionExpander` for template expansion functionality.
  """

  @type placeholder :: %{path: [String.t()], type: :simple | :iteration}

  @type t :: %__MODULE__{
          template: String.t(),
          placeholders: [placeholder()]
        }

  defstruct [:template, :placeholders]
end
