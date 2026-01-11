defmodule PtcRunner.SubAgent.Sigils do
  @moduledoc """
  Sigils for SubAgent templates.

  ## ~T Sigil

  The `~T` sigil creates a `PtcRunner.Template` struct at compile time with
  extracted placeholders.

  ### Examples

      import PtcRunner.SubAgent.Sigils

      ~T"Hello {{name}}"
      #=> %PtcRunner.Template{
      #=>   template: "Hello {{name}}",
      #=>   placeholders: [%{path: ["name"], type: :simple}]
      #=> }

      ~T"User {{user.name}} has {{count}} items"
      #=> %PtcRunner.Template{
      #=>   template: "User {{user.name}} has {{count}} items",
      #=>   placeholders: [
      #=>     %{path: ["user", "name"], type: :simple},
      #=>     %{path: ["count"], type: :simple}
      #=>   ]
      #=> }

  The sigil also supports heredoc syntax:

      ~T\"\"\"
      Hello {{name}},

      You have {{items.count}} items.
      \"\"\"

  Use `PtcRunner.SubAgent.Template.expand/2` to expand the template with values.

  ## Note on Elixir's Built-in ~T Sigil

  Elixir has a built-in `~T` sigil for Time structs (e.g., `~T[00:00:00]`).
  When you import this module, our `~T` sigil shadows the built-in one.

  This is safe in practice because:
  - The built-in `~T` uses square brackets: `~T[00:00:00]`
  - Our `~T` uses double quotes: `~T"Hello {{name}}"`
  - Files using Time literals typically don't import this module

  If you need both in the same file, you can use `Time.new!/3` instead of
  the Time sigil, or explicitly qualify the Time sigil with `import Kernel, only: [sigil_T: 2]`.
  """

  alias PtcRunner.SubAgent.Template, as: TemplateExpander
  alias PtcRunner.Template

  @doc """
  Creates a Template struct with compile-time placeholder extraction.

  ## Examples

  Note: Due to Elixir's built-in `~T` sigil for Time, doctests cannot be used
  here without import conflicts. See the test file for usage examples.

      import PtcRunner.SubAgent.Sigils
      template = ~T"Hello {{name}}"
      template.template
      #=> "Hello {{name}}"
      template.placeholders
      #=> [%{path: ["name"], type: :simple}]

  """
  defmacro sigil_T({:<<>>, _meta, [template]}, _modifiers) do
    placeholders = TemplateExpander.extract_placeholders(template)

    quote do
      %Template{
        template: unquote(template),
        placeholders: unquote(Macro.escape(placeholders))
      }
    end
  end
end
