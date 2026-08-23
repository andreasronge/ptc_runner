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

  @doc """
  Answers whether a rendered message is this diagnostic.

  `rejected_namespace/1` recovers the name and therefore requires the exact
  message; a caller that only needs to know which diagnostic it is holding sees
  the message already prefixed with its reason.
  """
  @spec unknown_namespace?(binary()) :: boolean()
  def unknown_namespace?(message) when is_binary(message),
    do: String.contains?(message, "unknown namespace ") and String.ends_with?(message, @hint)

  def unknown_namespace?(_message), do: false

  @data_not_callable_prefix "not callable: data/"
  @missing_data_grant_infix " is not a granted data name. Granted: "
  @rejected_data_symbol ~r{\A(?:[a-z_]+: )?data/\S+\z}
  @max_granted_data_names 32

  @doc """
  Answers whether a rendered message is a `not_callable` diagnostic for a
  `data/<name>` symbol.
  """
  @spec data_not_callable?(binary()) :: boolean()
  def data_not_callable?(message) when is_binary(message),
    do: String.starts_with?(message, @data_not_callable_prefix)

  def data_not_callable?(_message), do: false

  @doc """
  Builds the strict missing-grant diagnostic for `symbol`, listing `granted`.

  The list is sorted by the caller and truncated here at #{@max_granted_data_names}
  names, so a large grant set cannot push the rejected symbol out of a bounded
  renderer.
  """
  @spec missing_data_grant_message(binary(), [binary()]) :: binary()
  def missing_data_grant_message(symbol, granted)
      when is_binary(symbol) and is_list(granted) do
    symbol <> @missing_data_grant_infix <> format_granted_names(granted)
  end

  @doc """
  Answers whether a rendered message is the strict missing-grant diagnostic.

  It shares a home with the message it recognizes so the two cannot drift; the
  REPL frontend reads it to decide whether a workflow session should be told
  which switch opens a mission. The rejected half must be the entire prefix --
  a bare `data/<name>`, optionally behind one `reason: ` tag -- so another
  diagnostic that merely quotes this text, such as `not callable: "data/x is
  not a granted data name. …"`, is not mistaken for it.
  """
  @spec missing_data_grant?(binary()) :: boolean()
  def missing_data_grant?(message) when is_binary(message) do
    case String.split(message, @missing_data_grant_infix, parts: 2) do
      [rejected, _granted] -> Regex.match?(@rejected_data_symbol, rejected)
      _no_infix -> false
    end
  end

  def missing_data_grant?(_message), do: false

  defp format_granted_names([]), do: "(none)"

  defp format_granted_names(names) do
    shown = Enum.take(names, @max_granted_data_names)
    formatted = Enum.join(shown, ", ")

    if length(names) > @max_granted_data_names do
      formatted <> ", …"
    else
      formatted
    end
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
