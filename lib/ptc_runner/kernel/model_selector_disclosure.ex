defmodule PtcRunner.Kernel.ModelSelectorDisclosure do
  @moduledoc """
  The single rule deciding which configured model selectors a command may print.

  `doctor --show-model-selectors` and `models` both name the selector a host
  document configured for an LLM installation. An `openai-compat:` selector
  carries the operator's own endpoint, so it is withheld rather than disclosed.
  Both commands ask this module instead of reading `install` directly, so a new
  reader cannot publish what the older one refuses.
  """

  alias PtcRunner.Kernel.HostConfig

  @withheld_prefix "openai-compat:"

  @doc """
  Adds `model_selector` to every row whose alias names a disclosable selector.

  Rows are the public per-alias maps the `doctor` and `models` results carry,
  keyed by `"alias"`. A row without a disclosable selector is returned
  unchanged, so the field stays absent rather than null.
  """
  @spec annotate([map()], HostConfig.t() | nil) :: [map()]
  def annotate(rows, host) when is_list(rows) do
    Enum.map(rows, fn row ->
      case selector(host, Map.get(row, "alias")) do
        {:ok, selector} -> Map.put(row, "model_selector", selector)
        :withheld -> row
      end
    end)
  end

  @doc "Returns the disclosable selector one installed alias configured."
  @spec selector(HostConfig.t() | nil, term()) :: {:ok, binary()} | :withheld
  def selector(%HostConfig{install: install}, name) when is_binary(name) do
    case Map.fetch(install, name) do
      {:ok, %{source: :llm, model: selector}} when is_binary(selector) ->
        if String.starts_with?(selector, @withheld_prefix),
          do: :withheld,
          else: {:ok, selector}

      _other ->
        :withheld
    end
  end

  def selector(_host, _name), do: :withheld
end
