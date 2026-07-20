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

  @doc "Returns the pinned Java, JVM Clojure, and Babashka releases."
  @spec versions() :: map()
  def versions, do: @versions

  @doc "Returns the deterministic locale and timezone used by every oracle."
  @spec environment() :: %{locale: String.t(), timezone: String.t()}
  def environment, do: @environment
end
