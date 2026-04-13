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
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "docs/guides/getting-started.md",
          "docs/guides/routing-and-discovery.md",
          "docs/guides/observe-and-blockwise.md",
          "docs/support-matrix.md",
          "docs/known-limitations.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "SECURITY.md"
        ]
      ],
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
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end
end
