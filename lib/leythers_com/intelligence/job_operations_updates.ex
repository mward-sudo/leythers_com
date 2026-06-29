defmodule LeythersCom.Intelligence.JobOperationsUpdates do
  @moduledoc """
  Bridges Oban telemetry events into debounced PubSub updates for admin job operations views.
  """

  use GenServer

  @topic "admin:job_operations"
  @debounce_ms 200

  @telemetry_events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception],
    [:oban, :engine, :insert_job, :stop],
    [:oban, :engine, :retry_job, :stop],
    [:oban, :engine, :complete_job, :stop],
    [:oban, :engine, :discard_job, :stop],
    [:oban, :engine, :error_job, :stop],
    [:oban, :engine, :rescue_jobs, :stop],
    [:oban, :engine, :snooze_job, :stop]
  ]

  def topic, do: @topic

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(state) do
    :ok =
      :telemetry.attach_many(handler_id(), @telemetry_events, &__MODULE__.handle_event/4, self())

    {:ok, Map.merge(%{broadcast_pending?: false}, state)}
  end

  @impl true
  def handle_info({:oban_update, _event, _meta}, %{broadcast_pending?: false} = state) do
    _ = Process.send_after(self(), :broadcast, @debounce_ms)
    {:noreply, %{state | broadcast_pending?: true}}
  end

  def handle_info({:oban_update, _event, _meta}, state) do
    {:noreply, state}
  end

  def handle_info(:broadcast, state) do
    Phoenix.PubSub.broadcast(LeythersCom.PubSub, @topic, {:job_operations, :updated})
    {:noreply, %{state | broadcast_pending?: false}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(handler_id())
    :ok
  end

  def handle_event(event, _measurements, metadata, server_pid) do
    send(server_pid, {:oban_update, event, metadata})
  end

  defp handler_id, do: "job-operations-updates"
end
