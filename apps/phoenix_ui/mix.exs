defmodule PhoenixUi.MixProject do
  use Mix.Project

  def project do
    [
      app: :phoenix_ui,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {PhoenixUi.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :gnat,
        :telemetry_metrics_prometheus,
        :tls_certificate_check
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.1"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:httpoison, "~> 2.1"},
      {:telemetry_metrics_prometheus, "~> 1.0"},
      {:finch, "~> 0.13"},
      {:plug_cowboy, "~> 2.6"},
      {:ecto_sql, "~> 3.11"},
      {:floki, ">= 0.30.0", only: :test},
      {:oban, "~> 2.16"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:telemetry, "~> 1.2"},
      {:uuid, "~> 1.1"},
      {:opentelemetry, "~> 1.0"},
      {:opentelemetry_api, "~> 1.0"},
      {:tesla, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.0"},
      {:gnat, "~> 1.6"},
      {:gun, "~> 2.1", override: true},
      {:orchestrator, path: "../orchestrator", runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind phoenix_ui", "esbuild phoenix_ui"],
      "assets.deploy": [
        "tailwind phoenix_ui --minify",
        "esbuild phoenix_ui --minify",
        "phx.digest"
      ],
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  defp releases do
    [
      phoenix_ui: [
        include_executables_for: [:unix],
        applications: [
          runtime_tools: :permanent,
          orchestrator: :none
        ],
        steps: [:assemble, :tar],
        cookie: "aerophoenix_phoenix_ui_cookie",
        strip_beams: Mix.env() == :prod,
        validate_compile_env: false
      ]
    ]
  end
end
