defmodule PhoenixUi.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PhoenixUiWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:phoenix_ui, :dns_cluster_query, :ignore)},
      {Phoenix.PubSub, name: PhoenixUi.PubSub},
      {Finch, name: PhoenixUiWeb.Finch},
      PhoenixUi.Machines,
      PhoenixUiWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: PhoenixUi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PhoenixUiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
