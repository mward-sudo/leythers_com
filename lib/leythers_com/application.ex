defmodule LeythersCom.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias LeythersComWeb.Endpoint

  @impl true
  def start(_type, _args) do
    children = [
      LeythersComWeb.Telemetry,
      LeythersCom.Repo,
      {DNSCluster, query: Application.get_env(:leythers_com, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LeythersCom.PubSub},
      LeythersCom.Intelligence.JobOperationsUpdates,
      {Oban, Application.fetch_env!(:leythers_com, Oban)},
      LeythersCom.Scheduler,
      # Start to serve requests, typically the last entry
      LeythersComWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LeythersCom.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end
end
