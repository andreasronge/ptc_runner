defmodule LLMClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :llm_client,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.2"}
    ]
  end
end
