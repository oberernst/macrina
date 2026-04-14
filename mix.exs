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
      ],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ],
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        flags: [:error_handling, :unknown, :unmatched_returns]
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
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:benchee, "~> 1.3", only: [:dev, :test]},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
