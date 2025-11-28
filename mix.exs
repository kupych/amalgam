defmodule Amalgam.MixProject do
  use Mix.Project

  def project do
    [
      app: :amalgam,
      version: "0.0.1-dev",
      description: "Semantic merge driver for Elixir code",
      elixir: "~> 1.17",
      escript: [main_module: Amalgam],
      package: package(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [{:ex_doc, ">= 0.0.0", only: :dev, runtime: false}, {:sourceror, "~> 1.0"}]
  end

  defp package do
    [
      maintainers: ["kupych"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/kupych/amalgam"}
    ]
  end
end
