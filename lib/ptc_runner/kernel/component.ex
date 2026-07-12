defmodule PtcRunner.Kernel.Component do
  @moduledoc "A source-bearing, component-ID addressed bundle input."

  @id ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @enforce_keys [:id, :source, :dependencies, :origin]
  defstruct [:id, :source, :dependencies, :origin]

  @type t :: %__MODULE__{
          id: binary(),
          source: binary(),
          dependencies: [binary()],
          origin: binary()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_component}
  def new(opts) when is_list(opts) do
    with {:ok, id} <- valid_id(Keyword.get(opts, :id)),
         {:ok, source} <- valid_source(Keyword.get(opts, :source)),
         dependencies when is_list(dependencies) <- Keyword.get(opts, :dependencies, []),
         true <- Enum.all?(dependencies, &valid_id?/1),
         true <- dependencies == Enum.sort(Enum.uniq(dependencies)),
         origin when is_binary(origin) and byte_size(origin) <= 1_024 <-
           Keyword.get(opts, :origin, "memory") do
      {:ok, %__MODULE__{id: id, source: source, dependencies: dependencies, origin: origin}}
    else
      _ -> {:error, :invalid_component}
    end
  end

  defp valid_id(id) when is_binary(id),
    do: if(valid_id?(id), do: {:ok, id}, else: {:error, :invalid_component})

  defp valid_id(_id), do: {:error, :invalid_component}
  defp valid_id?(id) when is_binary(id), do: id =~ @id
  defp valid_id?(_id), do: false

  defp valid_source(source) when is_binary(source) and byte_size(source) > 0 do
    if String.valid?(source), do: {:ok, source}, else: {:error, :invalid_component}
  end

  defp valid_source(_source), do: {:error, :invalid_component}
end
