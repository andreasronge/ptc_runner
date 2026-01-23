defmodule GapAnalyzer.Tools do
  @moduledoc """
  Tools for the Gap Analyzer agent.

  Implements a search/retrieve pattern that simulates working with
  large documents where only small parts can be accessed at a time.

  - Search tools return summaries (small context)
  - Retrieve tools return full text (larger, but one at a time)
  """

  alias GapAnalyzer.Data

  @doc """
  Search regulations for sections matching a keyword.
  Returns summaries only, not full text.
  """
  @spec search_regulations(%{query: String.t()}) :: [
          %{id: String.t(), title: String.t(), section: String.t(), summary: String.t()}
        ]
  def search_regulations(%{"query" => query}) do
    Data.search_regulations(query)
  end

  @doc """
  Search policy for sections matching a keyword.
  Returns summaries only, not full text.
  """
  @spec search_policy(%{query: String.t()}) :: [
          %{id: String.t(), title: String.t(), section: String.t(), summary: String.t()}
        ]
  def search_policy(%{"query" => query}) do
    Data.search_policy(query)
  end

  @doc """
  Get full text of a specific regulation section.
  """
  @spec get_regulation(%{id: String.t()}) :: %{
          id: String.t(),
          title: String.t(),
          section: String.t(),
          full_text: String.t()
        }
  def get_regulation(%{"id" => id}) do
    case Data.get_regulation(id) do
      {:ok, section} ->
        %{
          id: section.id,
          title: section.title,
          section: section.section,
          full_text: section.full_text
        }

      {:error, msg} ->
        %{error: msg}
    end
  end

  @doc """
  Get full text of a specific policy section.
  """
  @spec get_policy(%{id: String.t()}) :: %{
          id: String.t(),
          title: String.t(),
          section: String.t(),
          full_text: String.t()
        }
  def get_policy(%{"id" => id}) do
    case Data.get_policy(id) do
      {:ok, section} ->
        %{
          id: section.id,
          title: section.title,
          section: section.section,
          full_text: section.full_text
        }

      {:error, msg} ->
        %{error: msg}
    end
  end
end
