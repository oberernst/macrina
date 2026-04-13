defmodule Macrina.MixProject do
  use Mix.Project

  def project do
    [
      app: :macrina,
      description: "A CoAP client and server for Elixir",
      version: "0.1.4",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: "https://github.com/oberernst/macrina",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/oberernst/macrina"}
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :logger, :ssl],
      mod: {Macrina.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.0"}
    ]
  end
end
