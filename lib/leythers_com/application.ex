defmodule LeythersCom.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias LeythersCom.Intelligence
  alias LeythersComWeb.Endpoint

  @impl true
  def start(_type, _args) do
    children = [
      LeythersComWeb.Telemetry,
      LeythersCom.Repo,
      {DNSCluster, query: Application.get_env(:leythers_com, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LeythersCom.PubSub},
      {Task.Supervisor, name: LeythersCom.TaskSupervisor},
      LeythersCom.Intelligence.LLMGuard,
      LeythersCom.Intelligence.JobOperationsUpdates,
      {Oban, Application.fetch_env!(:leythers_com, Oban)},
      LeythersCom.Scheduler,
      # Start to serve requests, typically the last entry
      LeythersComWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LeythersCom.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = result ->
        maybe_resume_editorial_work_after_boot()
        result

      other ->
        other
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end

  defp maybe_resume_editorial_work_after_boot do
    oban_config = Application.get_env(:leythers_com, Oban, [])
    test_mode? = Keyword.get(oban_config, :testing) == :inline

    Intelligence.restore_dev_llm_provider()
    Intelligence.maybe_apply_dev_provider_runtime_settings()

    if not test_mode? do
      Task.Supervisor.start_child(LeythersCom.TaskSupervisor, fn ->
        _ = Intelligence.recover_source_editorial_work()
      end)
    end
  end
end
