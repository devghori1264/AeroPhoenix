defmodule Orchestrator.MixProject do
  use Mix.Project

  def project do
    [
      app: :orchestrator,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      preferred_cli_env: ["test.fast": :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      mod: {Orchestrator.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :os_mon,
        :oban,
        :phoenix,
        :gnat,
        :tls_certificate_check
      ]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:plug_cowboy, "~> 2.7"},
      {:cors_plug, "~> 3.0"},
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.0.0"},
      {:finch, "~> 0.13"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus, "~> 1.0"},
      {:nx, "~> 0.6.4"},
      {:oban, "~> 2.16"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:gnat, "~> 1.6"},
      {:opentelemetry, "~> 1.0"},
      {:opentelemetry_exporter, "~> 1.0"},
      {:retry, "~> 0.16"},
      {:uuid, "~> 1.1"},
      {:exqlite, "~> 0.16"},
      {:jose, "~> 1.11"},
      {:grpc, "~> 0.9"},
      {:protobuf, "~> 0.11"},
      {:uniq, "~> 0.6.0"},
      {:bypass, github: "PSPDFKit-labs/bypass", only: :test}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "test.fast": ["test --exclude slow"]
    ]
  end

  defp releases do
    [
      orchestrator: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
