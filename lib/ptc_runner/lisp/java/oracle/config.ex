defmodule PtcRunner.Lisp.Java.Oracle.Config do
  @moduledoc """
  Pinned executable-oracle versions and deterministic process settings.

  JVM fixtures are authoritative only when produced by the exact Temurin and
  Clojure releases in `priv/java_oracle_versions.exs`. Babashka remains a fast
  secondary oracle and never grants exact overload coverage.
  """

  @versions_path "priv/java_oracle_versions.exs"
  @external_resource @versions_path
  @versions Code.eval_file(@versions_path) |> elem(0)

  @environment %{
    locale: "en_US",
    timezone: "UTC"
  }
  @babashka_locales [@environment.locale, @environment.locale |> String.split("_") |> hd()]

  @doc "Returns the pinned Java, JVM Clojure, and Babashka releases."
  @spec versions() :: map()
  def versions, do: @versions

  @doc "Returns the deterministic process locale and timezone requested for every oracle."
  @spec environment() :: %{locale: String.t(), timezone: String.t()}
  def environment, do: @environment

  @doc """
  Returns the accepted English locale labels from pinned Babashka native images.

  Babashka is a non-authoritative fast oracle. Its platform-specific native
  images may omit the region from Java's default locale even when the process
  environment requests en_US; locale-sensitive Java operations are excluded
  from its fixture subset.
  """
  @spec babashka_locales() :: [String.t()]
  def babashka_locales, do: @babashka_locales
end
