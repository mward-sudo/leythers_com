defmodule LeythersComWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("leythers_com.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("leythers_com.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("leythers_com.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("leythers_com.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("leythers_com.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Domain Metrics
      summary("leythers_com.content.manual_publish.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result]
      ),
      sum("leythers_com.content.manual_publish.stop.count", tags: [:result]),
      summary("leythers_com.content.cleanup.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result]
      ),
      sum("leythers_com.content.cleanup.stop.count", tags: [:result]),
      summary("leythers_com.content.provenance_history.query.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result]
      ),
      sum("leythers_com.content.provenance_history.query.stop.count", tags: [:result]),
      summary("leythers_com.intelligence.cost_ledger.upsert.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result]
      ),
      sum("leythers_com.intelligence.cost_ledger.upsert.stop.count", tags: [:result]),
      summary("leythers_com.intelligence.generation_budget.check.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result, :budget_state]
      ),
      sum("leythers_com.intelligence.generation_budget.check.stop.count",
        tags: [:result, :budget_state]
      ),
      summary("leythers_com.intelligence.dead_letter.query.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result]
      ),
      sum("leythers_com.intelligence.dead_letter.query.stop.count", tags: [:result]),
      summary("leythers_com.intelligence.dead_letter.retry.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result]
      ),
      sum("leythers_com.intelligence.dead_letter.retry.stop.count", tags: [:result]),
      summary("leythers_com.web.admin_overview.mount.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result, :budget_state]
      ),
      sum("leythers_com.web.admin_overview.mount.stop.count", tags: [:result, :budget_state]),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {LeythersComWeb, :count_users, []}
    ]
  end
end
