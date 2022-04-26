defmodule FluentdForwarder.MixProject do
  use Mix.Project

  def project do
    [
      app: :fluentd_forwarder,
      version: "0.1.2",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      name: "FluentdForwarder",
      source_url: "https://github.com/team-telnyx/elixir-fluentd-forwarder",
      description: description()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ranch, "~> 2.1"},
      {:msgpax, "~> 2.3"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Fluentd Forward Protocol in Elixir.
    """
  end

  defp package do
    [
      maintainers: ["Guilherme Balena Versiani <guilherme@telnyx.com>"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/team-telnyx/elixir-fluentd-forwarder"},
      files: ~w"lib mix.exs README.md LICENSE"
    ]
  end
end
