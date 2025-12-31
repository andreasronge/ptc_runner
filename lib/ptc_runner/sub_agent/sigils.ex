defmodule PtcRunner.SubAgent.Sigils do
  @moduledoc """
  Sigils for SubAgent prompt templates.

  ## ~PROMPT Sigil

  The `~PROMPT` sigil creates a `PtcRunner.Prompt` struct at compile time with
  extracted placeholders.

  ### Examples

      import PtcRunner.SubAgent.Sigils

      ~PROMPT"Hello {{name}}"
      #=> %PtcRunner.Prompt{
      #=>   template: "Hello {{name}}",
      #=>   placeholders: [%{path: ["name"], type: :simple}]
      #=> }

      ~PROMPT"User {{user.name}} has {{count}} items"
      #=> %PtcRunner.Prompt{
      #=>   template: "User {{user.name}} has {{count}} items",
      #=>   placeholders: [
      #=>     %{path: ["user", "name"], type: :simple},
      #=>     %{path: ["count"], type: :simple}
      #=>   ]
      #=> }

  The sigil also supports heredoc syntax:

      ~PROMPT\"\"\"
      Hello {{name}},

      You have {{items.count}} items.
      \"\"\"

  Use `PtcRunner.SubAgent.Template.expand/2` to expand the template with values.
  """

  alias PtcRunner.Prompt
  alias PtcRunner.SubAgent.Template

  @doc """
  Creates a Prompt struct with compile-time placeholder extraction.

  ## Examples

      iex> import PtcRunner.SubAgent.Sigils
      iex> prompt = ~PROMPT"Hello {{name}}"
      iex> prompt.template
      "Hello {{name}}"
      iex> prompt.placeholders
      [%{path: ["name"], type: :simple}]

  """
  defmacro sigil_PROMPT({:<<>>, _meta, [template]}, _modifiers) do
    placeholders = Template.extract_placeholders(template)

    quote do
      %Prompt{
        template: unquote(template),
        placeholders: unquote(Macro.escape(placeholders))
      }
    end
  end
end
