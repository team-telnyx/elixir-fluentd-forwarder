defmodule FluentdForwarder.MixProject do
  use Mix.Project

  def project do
    [
      app: :fluentd_forwarder,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {FluentdForwarder.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ranch, "~> 2.1"},
      {:msgpax, "~> 2.3"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
