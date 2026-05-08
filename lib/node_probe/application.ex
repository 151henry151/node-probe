defmodule NodeProbe.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      NodeProbeWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:node_probe, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: NodeProbe.PubSub},
      # Start a worker by calling: NodeProbe.Worker.start_link(arg)
      # {NodeProbe.Worker, arg},
      # Start to serve requests, typically the last entry
      NodeProbeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: NodeProbe.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NodeProbeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
