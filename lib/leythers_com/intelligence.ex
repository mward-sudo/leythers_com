defmodule LeythersCom.Intelligence do
  @moduledoc """
  Intelligence context for daily cost ledger upserts and monthly spend queries.
  """

  import Ecto.Query

  alias LeythersCom.Intelligence.ArticleGenerationDecision
  alias LeythersCom.Intelligence.CostLedger
  alias LeythersCom.Intelligence.JobEffectEvent
  alias LeythersCom.Repo
  alias Oban.Job

  @budget_config_key :intelligence_budget
  @job_bucket_states %{
    active: ["executing"],
    queued: ["available", "scheduled", "retryable"],
    terminal: ["completed", "discarded", "cancelled"]
  }

  @job_filter_states [
    "available",
    "scheduled",
    "executing",
    "retryable",
    "completed",
    "discarded",
    "cancelled"
  ]

  def upsert_cost_ledger(%{date: date} = attrs) when not is_nil(date) do
    started_at = System.monotonic_time()
    changeset = CostLedger.changeset(%CostLedger{}, attrs)

    result =
      if changeset.valid? do
        Repo.transaction(fn -> do_upsert_ledger(changeset, date, attrs) end)
      else
        {:error, changeset}
      end

    emit_cost_ledger_telemetry(result, started_at)
    result
  end

  def upsert_cost_ledger(attrs) do
    started_at = System.monotonic_time()
    result = {:error, CostLedger.changeset(%CostLedger{}, attrs)}
    emit_cost_ledger_telemetry(result, started_at)
    result
  end

  defp do_upsert_ledger(changeset, date, attrs) do
    case Repo.get_by(CostLedger, date: date) do
      nil ->
        Repo.insert!(changeset)

      existing ->
        updated = %{
          input_tokens: existing.input_tokens + (attrs[:input_tokens] || 0),
          output_tokens: existing.output_tokens + (attrs[:output_tokens] || 0),
          estimated_cost_gbp:
            Decimal.add(
              existing.estimated_cost_gbp,
              attrs[:estimated_cost_gbp] || Decimal.new("0")
            )
        }

        existing
        |> CostLedger.changeset(updated)
        |> Repo.update!()
    end
  end

  def monthly_spend(%Date{} = date) do
    start_of_month = Date.beginning_of_month(date)
    end_of_month = Date.end_of_month(date)

    result =
      CostLedger
      |> where([l], l.date >= ^start_of_month and l.date <= ^end_of_month)
      |> select([l], sum(l.estimated_cost_gbp))
      |> Repo.one()

    result || Decimal.new("0")
  end

  def recent_cost_ledgers(limit \\ 14)

  def recent_cost_ledgers(limit) when is_integer(limit) and limit > 0 do
    CostLedger
    |> order_by([ledger], desc: ledger.date)
    |> limit(^limit)
    |> Repo.all()
  end

  def recent_cost_ledgers(_limit), do: []

  def create_article_generation_decision(attrs) when is_map(attrs) do
    started_at = System.monotonic_time()

    result =
      %ArticleGenerationDecision{}
      |> ArticleGenerationDecision.changeset(attrs)
      |> Repo.insert()

    :telemetry.execute(
      [:leythers_com, :intelligence, :article_generation_decision, :create, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{result: normalize_budget_result(result)}
    )

    result
  end

  def create_article_generation_decision(_attrs) do
    {:error, ArticleGenerationDecision.changeset(%ArticleGenerationDecision{}, %{})}
  end

  def create_job_effect_event(attrs) when is_map(attrs) do
    %JobEffectEvent{}
    |> JobEffectEvent.changeset(attrs)
    |> Repo.insert()
  end

  def create_job_effect_event(_attrs) do
    {:error, JobEffectEvent.changeset(%JobEffectEvent{}, %{})}
  end

  def recent_job_effect_events(limit \\ 50)

  def recent_job_effect_events(limit) when is_integer(limit) and limit > 0 do
    JobEffectEvent
    |> order_by([event], desc: event.inserted_at)
    |> limit(^limit)
    |> preload([:permanent_article])
    |> Repo.all()
  end

  def recent_job_effect_events(_limit), do: []

  def job_effect_events_for_job(oban_job_id)

  def job_effect_events_for_job(oban_job_id) when is_integer(oban_job_id) and oban_job_id > 0 do
    JobEffectEvent
    |> where([event], event.oban_job_id == ^oban_job_id)
    |> order_by([event], asc: event.inserted_at)
    |> preload([:permanent_article])
    |> Repo.all()
  end

  def job_effect_events_for_job(_oban_job_id), do: []

  def recent_article_generation_decisions(limit \\ 25)

  def recent_article_generation_decisions(limit) when is_integer(limit) and limit > 0 do
    ArticleGenerationDecision
    |> order_by([decision], desc: decision.inserted_at)
    |> limit(^limit)
    |> preload([:permanent_article])
    |> Repo.all()
  end

  def recent_article_generation_decisions(_limit), do: []

  def list_failed_jobs(limit \\ 25)

  def list_failed_jobs(limit) when is_integer(limit) and limit > 0 do
    started_at = System.monotonic_time()

    jobs =
      Job
      |> where([job], job.state in ["retryable", "discarded"])
      |> order_by([job], desc: job.attempted_at, desc: job.inserted_at)
      |> limit(^limit)
      |> Repo.all()

    :telemetry.execute(
      [:leythers_com, :intelligence, :dead_letter, :query, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{result: :ok, job_count: length(jobs)}
    )

    jobs
  end

  def list_failed_jobs(_limit) do
    :telemetry.execute(
      [:leythers_com, :intelligence, :dead_letter, :query, :stop],
      %{duration: 0, count: 1},
      %{result: :invalid_limit, job_count: 0}
    )

    []
  end

  def retry_failed_job(job_id) when is_integer(job_id) and job_id > 0 do
    started_at = System.monotonic_time()
    result = Oban.retry_job(job_id)

    :telemetry.execute(
      [:leythers_com, :intelligence, :dead_letter, :retry, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{result: normalize_budget_result(result), job_id: job_id}
    )

    result
  end

  def retry_failed_job(_job_id), do: {:error, :invalid_job_id}

  def job_operations_bucket_counts(filters \\ %{}) when is_map(filters) do
    base_query = job_operations_base_query(filters)

    active_count =
      base_query
      |> where([job], job.state in ^Map.fetch!(@job_bucket_states, :active))
      |> Repo.aggregate(:count, :id)

    queued_count =
      base_query
      |> where([job], job.state in ^Map.fetch!(@job_bucket_states, :queued))
      |> Repo.aggregate(:count, :id)

    oban_terminal_count =
      base_query
      |> where([job], job.state in ^Map.fetch!(@job_bucket_states, :terminal))
      |> Repo.aggregate(:count, :id)

    history_terminal_count = terminal_history_count(filters)

    %{
      active: active_count,
      queued: queued_count,
      terminal:
        if(history_terminal_count > 0, do: history_terminal_count, else: oban_terminal_count)
    }
  end

  def list_job_operations_jobs(bucket, opts \\ %{}) when is_map(opts) do
    bucket = normalize_bucket(bucket)
    page = positive_integer(opts[:page], 1)
    per_page = positive_integer(opts[:per_page], 20) |> min(100)

    case bucket do
      :terminal ->
        list_terminal_job_operations_jobs(opts, page, per_page)

      _ ->
        list_live_job_operations_jobs(bucket, opts, page, per_page)
    end
  end

  defp list_live_job_operations_jobs(bucket, opts, page, per_page) do
    states = Map.fetch!(@job_bucket_states, bucket)

    query =
      opts
      |> job_operations_base_query()
      |> where([job], job.state in ^states)

    total_count = Repo.aggregate(query, :count, :id)
    total_pages = if total_count == 0, do: 1, else: div(total_count + per_page - 1, per_page)
    current_page = min(page, total_pages)
    offset = (current_page - 1) * per_page

    jobs =
      query
      |> order_by([job], desc: job.attempted_at, desc: job.inserted_at, desc: job.id)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    %{
      entries: jobs,
      page: current_page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages
    }
  end

  defp list_terminal_job_operations_jobs(opts, page, per_page) do
    history_count = terminal_history_count(opts)

    if history_count > 0 do
      offset = (page - 1) * per_page

      terminal_history_entries =
        opts
        |> terminal_history_query()
        |> order_by([event], desc: event.inserted_at)
        |> limit(^per_page)
        |> offset(^offset)
        |> Repo.all()
        |> Enum.map(&terminal_event_to_job_row/1)

      total_pages =
        if history_count == 0, do: 1, else: div(history_count + per_page - 1, per_page)

      current_page = min(page, total_pages)

      %{
        entries: terminal_history_entries,
        page: current_page,
        per_page: per_page,
        total_count: history_count,
        total_pages: total_pages
      }
    else
      list_live_job_operations_jobs(:terminal, opts, page, per_page)
    end
  end

  def job_operations_filter_options do
    job_queues =
      Job
      |> job_operations_scope()
      |> distinct([job], job.queue)
      |> select([job], job.queue)
      |> order_by([job], asc: job.queue)
      |> Repo.all()

    history_queues =
      JobEffectEvent
      |> job_effect_events_scope()
      |> distinct([event], event.queue)
      |> select([event], event.queue)
      |> order_by([event], asc: event.queue)
      |> Repo.all()

    job_workers =
      Job
      |> job_operations_scope()
      |> distinct([job], job.worker)
      |> select([job], job.worker)
      |> order_by([job], asc: job.worker)
      |> Repo.all()

    history_workers =
      JobEffectEvent
      |> job_effect_events_scope()
      |> distinct([event], event.worker)
      |> select([event], event.worker)
      |> order_by([event], asc: event.worker)
      |> Repo.all()

    queues = (job_queues ++ history_queues) |> Enum.uniq() |> Enum.sort()
    workers = (job_workers ++ history_workers) |> Enum.uniq() |> Enum.sort()

    %{queues: queues, workers: workers, states: @job_filter_states}
  end

  def job_operations_detail(job_id) when is_integer(job_id) and job_id > 0 do
    events = job_effect_events_for_job(job_id)
    job = Repo.get(Job, job_id) || synthesize_job_from_events(events, job_id)

    if is_nil(job) and events == [] do
      nil
    else
      %{job: job, events: events}
    end
  end

  def job_operations_detail(_job_id), do: nil

  def monthly_budget_state(%Date{} = date, monthly_budget_gbp) do
    monthly_spend = monthly_spend(date)
    monthly_budget = to_decimal(monthly_budget_gbp)
    warning_threshold = Decimal.mult(monthly_budget, Decimal.new("0.8"))

    cond do
      Decimal.compare(monthly_spend, monthly_budget) != :lt ->
        :over_budget

      Decimal.compare(monthly_spend, warning_threshold) != :lt ->
        :near_budget

      true ->
        :under_budget
    end
  end

  def monthly_generation_cap do
    @budget_config_key
    |> Application.get_env(:leythers_com, [])
    |> Keyword.get(:monthly_cap_gbp, "10.00")
    |> to_decimal()
  end

  def generation_budget_state(%Date{} = date, override \\ nil) do
    date
    |> effective_monthly_cap(override)
    |> then(&monthly_budget_state(date, &1))
  end

  def generation_allowed?(%Date{} = date, override \\ nil) do
    generation_budget_state(date, override) != :over_budget
  end

  def ensure_generation_allowed!(%Date{} = date, override \\ nil) do
    started_at = System.monotonic_time()
    budget_state = generation_budget_state(date, override)

    result =
      if budget_state == :over_budget do
        {:error, :over_budget}
      else
        :ok
      end

    :telemetry.execute(
      [:leythers_com, :intelligence, :generation_budget, :check, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{result: normalize_budget_result(result), budget_state: budget_state}
    )

    result
  end

  def effective_monthly_cap(%Date{} = _date, nil), do: monthly_generation_cap()

  def effective_monthly_cap(%Date{} = date, override) when is_map(override) do
    default_cap = monthly_generation_cap()

    override_cap =
      Map.get(override, :monthly_cap_gbp) || Map.get(override, "monthly_cap_gbp")

    expires_on = Map.get(override, :expires_on) || Map.get(override, "expires_on")

    cond do
      is_nil(override_cap) or is_nil(expires_on) ->
        default_cap

      not match?(%Date{}, expires_on) ->
        default_cap

      Date.end_of_month(date) != expires_on ->
        default_cap

      true ->
        override_cap = to_decimal(override_cap)

        if Decimal.compare(override_cap, default_cap) != :gt do
          default_cap
        else
          override_cap
        end
    end
  end

  defp to_decimal(%Decimal{} = decimal), do: decimal
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)

  defp emit_cost_ledger_telemetry(result, started_at) do
    :telemetry.execute(
      [:leythers_com, :intelligence, :cost_ledger, :upsert, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{result: normalize_budget_result(result)}
    )
  end

  defp bucket_states(bucket) when is_binary(bucket) do
    case bucket do
      "active" -> Map.fetch!(@job_bucket_states, :active)
      "queued" -> Map.fetch!(@job_bucket_states, :queued)
      "terminal" -> Map.fetch!(@job_bucket_states, :terminal)
      _ -> Map.fetch!(@job_bucket_states, :active)
    end
  end

  defp bucket_states(bucket) when is_atom(bucket) do
    Map.get(@job_bucket_states, bucket, Map.fetch!(@job_bucket_states, :active))
  end

  defp bucket_states(_bucket), do: Map.fetch!(@job_bucket_states, :active)

  defp normalize_bucket(bucket) do
    states = bucket_states(bucket)

    cond do
      states == Map.fetch!(@job_bucket_states, :active) -> :active
      states == Map.fetch!(@job_bucket_states, :queued) -> :queued
      true -> :terminal
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp job_operations_base_query(filters) do
    queue = Map.get(filters, :queue) || Map.get(filters, "queue")
    worker = Map.get(filters, :worker) || Map.get(filters, "worker")
    state = Map.get(filters, :state) || Map.get(filters, "state")

    time_window_hours =
      Map.get(filters, :time_window_hours) || Map.get(filters, "time_window_hours")

    Job
    |> job_operations_scope()
    |> maybe_filter_queue(queue)
    |> maybe_filter_worker(worker)
    |> maybe_filter_state(state)
    |> maybe_filter_time_window_hours(time_window_hours)
  end

  defp job_operations_scope(query) do
    where(
      query,
      [job],
      like(job.worker, "LeythersCom.Ingestion.%") or
        like(job.worker, "LeythersCom.Intelligence.%")
    )
  end

  defp job_effect_events_scope(query) do
    where(
      query,
      [event],
      like(event.worker, "LeythersCom.Ingestion.%") or
        like(event.worker, "LeythersCom.Intelligence.%")
    )
  end

  defp maybe_filter_queue(query, queue) when is_binary(queue) and queue != "" do
    where(query, [job], job.queue == ^queue)
  end

  defp maybe_filter_queue(query, _queue), do: query

  defp maybe_filter_worker(query, worker) when is_binary(worker) and worker != "" do
    where(query, [job], ilike(job.worker, ^"%#{worker}%"))
  end

  defp maybe_filter_worker(query, _worker), do: query

  defp maybe_filter_state(query, state) when state in @job_filter_states do
    where(query, [job], job.state == ^state)
  end

  defp maybe_filter_state(query, _state), do: query

  defp maybe_filter_event_queue(query, queue) when is_binary(queue) and queue != "" do
    where(query, [event], event.queue == ^queue)
  end

  defp maybe_filter_event_queue(query, _queue), do: query

  defp maybe_filter_event_worker(query, worker) when is_binary(worker) and worker != "" do
    where(query, [event], ilike(event.worker, ^"%#{worker}%"))
  end

  defp maybe_filter_event_worker(query, _worker), do: query

  defp maybe_filter_event_state(query, state) when state in @job_filter_states do
    where(query, [event], event.state == ^state)
  end

  defp maybe_filter_event_state(query, _state), do: query

  defp maybe_filter_event_time_window_hours(query, time_window_hours) do
    case positive_integer(time_window_hours, 0) do
      hours when hours > 0 ->
        threshold = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
        where(query, [event], event.inserted_at >= ^threshold)

      _ ->
        query
    end
  end

  defp terminal_history_query(filters) do
    queue = Map.get(filters, :queue) || Map.get(filters, "queue")
    worker = Map.get(filters, :worker) || Map.get(filters, "worker")
    state = Map.get(filters, :state) || Map.get(filters, "state")

    time_window_hours =
      Map.get(filters, :time_window_hours) || Map.get(filters, "time_window_hours")

    terminal_states = Map.fetch!(@job_bucket_states, :terminal)

    base_query =
      JobEffectEvent
      |> job_effect_events_scope()
      |> where([event], event.state in ^terminal_states)
      |> maybe_filter_event_queue(queue)
      |> maybe_filter_event_worker(worker)
      |> maybe_filter_event_state(state)
      |> maybe_filter_event_time_window_hours(time_window_hours)

    latest_per_job =
      base_query
      |> group_by([event], event.oban_job_id)
      |> select([event], %{oban_job_id: event.oban_job_id, inserted_at: max(event.inserted_at)})

    from(event in base_query,
      join: latest in subquery(latest_per_job),
      on: event.oban_job_id == latest.oban_job_id and event.inserted_at == latest.inserted_at
    )
  end

  defp terminal_history_count(filters) do
    filters
    |> terminal_history_query()
    |> Repo.aggregate(:count, :id)
  end

  defp terminal_event_to_job_row(event) do
    %{
      id: event.oban_job_id,
      state: event.state,
      queue: event.queue,
      worker: event.worker,
      attempt: event.attempt,
      max_attempts: nil,
      inserted_at: event.inserted_at,
      attempted_at: nil,
      args: nil,
      source: :history
    }
  end

  defp synthesize_job_from_events([], _job_id), do: nil

  defp synthesize_job_from_events(events, job_id) do
    latest = List.last(events)

    %{
      id: job_id,
      state: latest.state,
      queue: latest.queue,
      worker: latest.worker,
      attempt: latest.attempt,
      max_attempts: nil,
      inserted_at: latest.inserted_at,
      attempted_at: nil,
      args: nil,
      attempted_by: nil,
      source: :history
    }
  end

  defp maybe_filter_time_window_hours(query, time_window_hours) do
    case positive_integer(time_window_hours, 0) do
      hours when hours > 0 ->
        threshold = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
        where(query, [job], job.inserted_at >= ^threshold)

      _ ->
        query
    end
  end

  defp normalize_budget_result(:ok), do: :ok
  defp normalize_budget_result({:ok, _}), do: :ok
  defp normalize_budget_result(_), do: :error
end
