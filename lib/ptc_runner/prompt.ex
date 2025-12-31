defmodule PtcRunner.Prompt do
  @moduledoc """
  Represents a prompt template with extracted placeholders.

  A `Prompt` struct contains:
  - `template`: The raw template string with `{{placeholder}}` syntax
  - `placeholders`: List of extracted placeholders with their paths

  ## Examples

      iex> PtcRunner.Prompt.__struct__()
      %PtcRunner.Prompt{template: nil, placeholders: nil}

  Prompts are typically created using the `~PROMPT` sigil:

      import PtcRunner.SubAgent.Sigils
      ~PROMPT"Hello {{name}}"

  See `PtcRunner.SubAgent.Template` for template expansion functionality.
  """

  @type placeholder :: %{path: [String.t()], type: :simple | :iteration}

  @type t :: %__MODULE__{
          template: String.t(),
          placeholders: [placeholder()]
        }

  defstruct [:template, :placeholders]
end
