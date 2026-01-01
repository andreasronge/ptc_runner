defmodule PtcRunner.Lisp.Schema do
  @moduledoc """
  Schema and prompt generation for PTC-Lisp.

  Provides the language reference prompt for LLM code generation.
  This module is the **single source of truth** for the PTC-Lisp LLM prompt.
  """

  # Register the markdown file as an external resource for recompilation
  @external_resource Path.join(__DIR__, "../../../priv/prompts/ptc-lisp-reference.md")

  # Extract prompt content at compile time from the markdown file
  @prompt_content (fn ->
                     markdown_path =
                       Path.join(__DIR__, "../../../priv/prompts/ptc-lisp-reference.md")

                     content = File.read!(markdown_path)

                     case String.split(content, "<!-- PTC_PROMPT_START -->") do
                       [_before, after_start] ->
                         case String.split(after_start, "<!-- PTC_PROMPT_END -->") do
                           [prompt_text, _after_end] ->
                             String.trim(prompt_text)

                           _ ->
                             raise "Missing PTC_PROMPT_END marker in #{markdown_path}"
                         end

                       _ ->
                         raise "Missing PTC_PROMPT_START marker in #{markdown_path}"
                     end
                   end).()

  @doc """
  Returns the PTC-Lisp language reference prompt for LLM code generation.

  This is the **single source of truth** for the PTC-Lisp language reference.
  All documentation and tools should use this API rather than duplicating the content.

  The prompt contains:
  - Data types (nil, booleans, numbers, strings, keywords, vectors, maps)
  - Accessing data (ctx/, memory/)
  - Special forms (let, if, when, cond, fn)
  - Threading macros (->, ->>)
  - Predicate builders (where, all-of, any-of, none-of)
  - Core functions (filter, map, sort-by, count, sum-by, etc.)
  - Tool calls
  - Memory result contract
  - Common mistakes to avoid

  ## Example

      iex> prompt = PtcRunner.Lisp.Schema.to_prompt()
      iex> String.contains?(prompt, "PTC-Lisp")
      true

  ## Usage in LLM System Prompt

      system_prompt = \"\"\"
      You are a data analyst. Query data using PTC-Lisp programs.

      Available datasets: ctx/users, ctx/orders

      \#{PtcRunner.Lisp.Schema.to_prompt()}
      \"\"\"
  """
  @spec to_prompt() :: String.t()
  def to_prompt do
    @prompt_content
  end
end
