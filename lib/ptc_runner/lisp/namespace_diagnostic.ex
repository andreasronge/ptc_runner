defmodule PtcRunner.Lisp.NamespaceDiagnostic do
  @moduledoc false

  alias PtcRunner.Lisp.Java.Surface, as: JavaSurface

  @builtin_namespaces [
    "data/",
    "tool/",
    "json/",
    "clojure.core/",
    "core/",
    "clojure.string/",
    "str/",
    "string/",
    "clojure.set/",
    "set/",
    "clojure.walk/",
    "walk/",
    "regex/"
  ]
  @hint "For JSON parsing use json/parse-string (not cheshire.core/...)."

  @doc false
  @spec available_namespaces() :: [binary()]
  def available_namespaces do
    (@builtin_namespaces ++ JavaSurface.available_namespace_labels() ++ ["java.util.Date."])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec details(binary()) :: map()
  def details(namespace) when is_binary(namespace) do
    %{
      rejected_namespace: namespace,
      available_namespaces: available_namespaces()
    }
  end

  @doc false
  @spec message(binary(), [binary()]) :: binary()
  def message(namespace, available_namespaces \\ available_namespaces())
      when is_binary(namespace) and is_list(available_namespaces) do
    "unknown namespace #{namespace}/. Available namespaces: " <>
      Enum.join(available_namespaces, ", ") <> ". " <> @hint
  end

  @doc false
  @spec rejected_namespace(binary()) :: {:ok, binary()} | :error
  def rejected_namespace(message) when is_binary(message) do
    prefix = "unknown namespace "

    suffix =
      "/. Available namespaces: " <> Enum.join(available_namespaces(), ", ") <> ". " <> @hint

    with true <- String.starts_with?(message, prefix),
         true <- String.ends_with?(message, suffix),
         namespace_bytes = byte_size(message) - byte_size(prefix) - byte_size(suffix),
         true <- namespace_bytes > 0 do
      {:ok, binary_part(message, byte_size(prefix), namespace_bytes)}
    else
      _invalid -> :error
    end
  end

  def rejected_namespace(_message), do: :error
end
