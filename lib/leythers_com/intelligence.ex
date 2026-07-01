defmodule LeythersCom.Intelligence do
  @moduledoc """
  Intelligence context for daily cost ledger upserts and monthly spend queries.
  """

  import Ecto.Query

  alias LeythersCom.Intelligence.ArticleGenerationDecision
  alias LeythersCom.Intelligence.CostLedger
  alias LeythersCom.Intelligence.HomepageRankingDecision
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

  def list_jobs_by_bucket(bucket, filters \\ %{})

  def list_jobs_by_bucket(bucket, filters) when is_atom(bucket) and is_map(filters) do
    states = Map.get(@job_bucket_states, bucket, Map.fetch!(@job_bucket_states, :active))

    filters
    |> job_operations_base_query()
    |> where([job], job.state in ^states)
    |> order_by([job], desc: job.attempted_at, desc: job.inserted_at)
    |> Repo.all()
  end

  def list_jobs_by_bucket(_bucket, _filters), do: []

  def list_processing_activity(limit \\ 60)

  def list_processing_activity(limit) when is_integer(limit) and limit > 0 do
    live = live_activity_jobs()
    editorial = editorial_activity_runs(limit)
    ingestion = ingestion_activity_runs(limit)
    ranking = ranking_activity_runs(limit)

    (live ++ editorial ++ ingestion ++ ranking)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(limit)
  end

  def list_processing_activity(_limit), do: []

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

  def cancel_all_jobs do
    started_at = System.monotonic_time()

    # Cancel all jobs in non-terminal states (active and queued)
    non_terminal_states =
      Map.fetch!(@job_bucket_states, :active) ++ Map.fetch!(@job_bucket_states, :queued)

    jobs_to_cancel =
      Job
      |> where([job], job.state in ^non_terminal_states)
      |> Repo.all()

    cancelled_count =
      jobs_to_cancel
      |> Enum.count(fn job ->
        case Oban.cancel_job(job.id) do
          {:ok, _job} -> true
          _ -> false
        end
      end)

    :telemetry.execute(
      [:leythers_com, :intelligence, :cancel_all_jobs, :stop],
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{result: :ok, cancelled_count: cancelled_count}
    )

    {:ok, %{cancelled_jobs: cancelled_count}}
  end

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

  def list_processes(opts \\ %{}) when is_map(opts) do
    page = positive_integer(opts[:page], 1)
    per_page = positive_integer(opts[:per_page], 20) |> min(100)

    # Fetch executing jobs
    executing_processes = list_executing_jobs_as_processes()

    base_query =
      JobEffectEvent
      |> where([event], not is_nil(event.process_run_id))
      |> job_effect_events_scope()

    # Get count of distinct processes
    count_query =
      base_query
      |> distinct([event], event.process_run_id)
      |> select([event], event.process_run_id)

    completed_count = Repo.aggregate(count_query, :count, :id)
    total_count = completed_count + Enum.count(executing_processes)
    total_pages = if total_count == 0, do: 1, else: div(total_count + per_page - 1, per_page)
    current_page = min(page, total_pages)
    offset = (current_page - 1) * per_page

    # Get processes with their max timestamp using subquery
    process_query =
      base_query
      |> group_by([event], event.process_run_id)
      |> select([event], {event.process_run_id, max(event.inserted_at)})
      |> order_by([event], desc: max(event.inserted_at))

    completed_processes =
      process_query
      |> Repo.all()
      |> Enum.map(fn {process_run_id, _} -> process_summary(process_run_id) end)
      |> Enum.reject(&is_nil/1)

    # Sort executing jobs by timestamp, keep them first
    sorted_executing =
      executing_processes
      |> Enum.sort_by(& &1.last_updated_at, :desc)

    # Sort completed jobs by timestamp
    sorted_completed =
      completed_processes
      |> Enum.sort_by(& &1.last_updated_at, :desc)

    # Combine: executing jobs always first, then completed
    all_processes = sorted_executing ++ sorted_completed

    # Apply pagination
    paginated_processes =
      all_processes
      |> Enum.drop(offset)
      |> Enum.take(per_page)

    %{
      entries: paginated_processes,
      page: current_page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages
    }
  end

  def process_summary(process_run_id) when is_binary(process_run_id) do
    events =
      JobEffectEvent
      |> where([event], event.process_run_id == ^process_run_id)
      |> order_by([event], asc: event.inserted_at)
      |> Repo.all()

    case events do
      [] ->
        nil

      _ ->
        first_event = List.first(events)
        last_event = List.last(events)

        {process_type, process_name} = infer_process_info(events)

        # Count decision outcomes
        completed = Enum.count(events, &(&1.state in ["completed"]))
        discarded = Enum.count(events, &(&1.state in ["discarded"]))
        executing = Enum.count(events, &(&1.state in ["executing"]))
        failed = Enum.count(events, &(&1.state in ["retryable"]))

        %{
          process_run_id: process_run_id,
          process_type: process_type,
          process_name: process_name,
          status: infer_process_status(events),
          started_at: first_event.inserted_at,
          last_updated_at: last_event.inserted_at,
          event_count: Enum.count(events),
          stats: %{
            completed: completed,
            discarded: discarded,
            executing: executing,
            failed: failed
          }
        }
    end
  end

  defp infer_process_info(events) do
    first_event = List.first(events)

    case first_event.worker do
      "LeythersCom.Ingestion.FetchRssFeedWorker" ->
        {:ingestion, "RSS Feed Ingestion"}

      "LeythersCom.Intelligence.SourceEditorialWorker" ->
        source_count = Enum.count(events, &(not Enum.empty?(&1.source_ids)))
        {:editorial, "Editorial Review: #{source_count} sources"}

      worker ->
        # Fallback for other workers
        {:job, worker}
    end
  end

  defp infer_process_status(events) do
    states = Enum.map(events, & &1.state)

    cond do
      Enum.any?(states, &(&1 == "executing")) -> :running
      Enum.any?(states, &(&1 == "retryable")) -> :failed
      Enum.any?(states, &(&1 == "discarded")) -> :discarded
      Enum.all?(states, &(&1 == "completed")) -> :completed
      true -> :mixed
    end
  end

  def process_events(process_run_id) when is_binary(process_run_id) do
    # Executing jobs (with process_run_id like "oban-217") have no events yet
    # But we can fetch pending sources being processed
    if String.starts_with?(process_run_id, "oban-") do
      []
    else
      JobEffectEvent
      |> where([event], event.process_run_id == ^process_run_id)
      |> order_by([event], asc: event.inserted_at)
      |> preload(:permanent_article)
      |> Repo.all()
    end
  end

  def executing_job_details(job_id) when is_integer(job_id) do
    from(j in "oban_jobs",
      where: j.id == ^job_id,
      select: %{
        id: j.id,
        worker: j.worker,
        state: j.state,
        args: j.args,
        attempted_at: j.attempted_at
      }
    )
    |> Repo.one()
  end

  def pending_editorial_sources(limit \\ 50) do
    from(source in "raw_sources",
      where: source.status == "pending",
      order_by: [asc: source.inserted_at],
      limit: ^limit,
      select: %{
        id: source.id,
        title: source.title,
        external_published_at: source.external_published_at,
        inserted_at: source.inserted_at
      }
    )
    |> Repo.all()
  end

  def job_operations_progress_snapshot do
    running_jobs =
      from(job in "oban_jobs",
        where: job.state == "executing",
        select: count(job.id)
      )
      |> Repo.one()

    queued_jobs =
      from(job in "oban_jobs",
        where: job.state in ["available", "scheduled", "retryable"],
        select: count(job.id)
      )
      |> Repo.one()

    pending_sources =
      from(source in "raw_sources",
        where: source.status == "pending",
        select: count(source.id)
      )
      |> Repo.one()

    %{
      running_jobs: running_jobs || 0,
      queued_jobs: queued_jobs || 0,
      pending_sources: pending_sources || 0,
      left_to_run: queued_jobs || 0
    }
  end

  def list_executing_jobs_as_processes do
    # Fetch currently executing Oban jobs, excluding those that have already created completed events
    executing_job_ids =
      from(j in "oban_jobs",
        where: j.state in ["executing", "retryable"],
        select: j.id,
        order_by: [desc: j.attempted_at]
      )
      |> Repo.all()

    # Filter out jobs that have completed events (safety check for stuck jobs)
    executing_job_ids_with_no_completion =
      executing_job_ids
      |> Enum.reject(fn job_id ->
        from(e in "job_effect_events",
          where: e.oban_job_id == ^job_id and e.state == "completed",
          limit: 1,
          select: e.id
        )
        |> Repo.exists?()
      end)

    # Now fetch details for the filtered jobs
    from(j in "oban_jobs",
      where: j.id in ^executing_job_ids_with_no_completion,
      select: %{
        id: j.id,
        worker: j.worker,
        state: j.state,
        attempted_at: j.attempted_at,
        args: j.args
      },
      order_by: [desc: j.attempted_at]
    )
    |> Repo.all()
    |> Enum.map(&oban_job_to_process_summary/1)
    |> Enum.reject(&is_nil/1)
  end

  defp oban_job_to_process_summary(%{
         worker: worker,
         state: state,
         attempted_at: attempted_at,
         id: job_id
       }) do
    {process_type, process_name} = infer_process_info_from_worker(worker)

    process_status =
      case state do
        "executing" -> :running
        "retryable" -> :failed
        _ -> :mixed
      end

    timestamp = attempted_at || DateTime.utc_now()

    %{
      process_run_id: "oban-#{job_id}",
      process_type: process_type,
      process_name: process_name,
      status: process_status,
      started_at: timestamp,
      last_updated_at: timestamp,
      event_count: 0,
      stats: %{completed: 0, discarded: 0, executing: 1, failed: 0},
      is_executing: true
    }
  end

  defp infer_process_info_from_worker(worker) do
    case worker do
      "LeythersCom.Ingestion.FetchRssFeedWorker" ->
        {:ingestion, "RSS Feed Ingestion"}

      "LeythersCom.Intelligence.SourceEditorialWorker" ->
        {:editorial, "Editorial Review"}

      worker ->
        {:job, worker}
    end
  end

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

  # ── Processing activity timeline ────────────────────────────────────────────

  defp live_activity_jobs do
    live_states =
      Map.fetch!(@job_bucket_states, :active) ++ Map.fetch!(@job_bucket_states, :queued)

    Job
    |> job_operations_scope()
    |> where([job], job.state in ^live_states)
    |> order_by([job], asc: job.inserted_at)
    |> Repo.all()
    |> Enum.map(&job_to_live_activity_item/1)
  end

  defp job_to_live_activity_item(job) do
    %{
      id: "live-#{job.id}",
      type: :live_job,
      subtype: worker_activity_subtype(job.worker),
      timestamp: job.attempted_at || job.inserted_at,
      state: job.state,
      job_id: job.id,
      worker: job.worker,
      queue: job.queue,
      args: job.args || %{}
    }
  end

  defp worker_activity_subtype(worker) when is_binary(worker) do
    cond do
      String.contains?(worker, "SourceEditorialWorker") -> :editorial
      String.contains?(worker, "FetchRssFeedWorker") -> :ingestion
      true -> :other
    end
  end

  defp worker_activity_subtype(_), do: :other

  defp editorial_activity_runs(limit) do
    events =
      JobEffectEvent
      |> job_effect_events_scope()
      |> where([event], like(event.worker, "%.SourceEditorialWorker"))
      |> order_by([event], desc: event.inserted_at)
      |> limit(^(limit * 10))
      |> preload([:permanent_article])
      |> Repo.all()

    events_by_job = Enum.group_by(events, & &1.oban_job_id)

    run_ids =
      events
      |> Enum.map(&get_run_id_from_event/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    decisions_by_run =
      if run_ids == [] do
        %{}
      else
        ArticleGenerationDecision
        |> where([d], d.run_id in ^run_ids)
        |> order_by([d], asc: d.inserted_at)
        |> preload([:permanent_article])
        |> Repo.all()
        |> Enum.group_by(& &1.run_id)
      end

    events_by_job
    |> Enum.map(fn {job_id, job_events} ->
      sorted_events = Enum.sort_by(job_events, & &1.inserted_at, DateTime)
      latest = List.last(sorted_events)

      job_run_ids =
        sorted_events
        |> Enum.map(&get_run_id_from_event/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      job_decisions =
        job_run_ids
        |> Enum.flat_map(&Map.get(decisions_by_run, &1, []))

      %{
        id: "editorial-#{job_id}",
        type: :editorial_run,
        subtype: :editorial,
        timestamp: latest.inserted_at,
        state: latest.state,
        job_id: job_id,
        clusters: build_editorial_clusters(sorted_events, job_decisions),
        stats: editorial_run_stats(job_decisions)
      }
    end)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp get_run_id_from_event(event) do
    Map.get(event.change_details || %{}, "run_id")
  end

  defp build_editorial_clusters(events, decisions) do
    Enum.map(events, fn event ->
      event_source_ids = MapSet.new(event.source_ids || [])

      matched_decision =
        Enum.find(decisions, fn d ->
          d_ids = MapSet.new(d.source_ids || [])
          not MapSet.disjoint?(event_source_ids, d_ids)
        end)

      %{
        decision: matched_decision,
        event: event,
        sources: get_in(event.source_input_snapshot || %{}, ["sources"]) || [],
        action: event.decision_action
      }
    end)
  end

  defp editorial_run_stats(decisions) do
    created = Enum.count(decisions, &(&1.decision_action == "created"))
    updated = Enum.count(decisions, &(&1.decision_action == "updated"))

    skipped =
      Enum.count(decisions, &(&1.decision_action in ["skipped_budget", "skipped_publish_error"]))

    total_in = Enum.sum(Enum.map(decisions, & &1.input_tokens))
    total_out = Enum.sum(Enum.map(decisions, & &1.output_tokens))

    %{
      clusters: length(decisions),
      created: created,
      updated: updated,
      skipped: skipped,
      input_tokens: total_in,
      output_tokens: total_out,
      llm_used: total_in > 0
    }
  end

  defp ingestion_activity_runs(limit) do
    JobEffectEvent
    |> job_effect_events_scope()
    |> where([event], like(event.worker, "%.FetchRssFeedWorker"))
    |> order_by([event], desc: event.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&ingestion_event_to_activity_item/1)
  end

  defp ingestion_event_to_activity_item(event) do
    feed = get_in(event.source_input_snapshot || %{}, ["feed"]) || %{}
    details = event.change_details || %{}
    items = get_in(event.source_input_snapshot || %{}, ["items"]) || []

    %{
      id: "ingestion-#{event.oban_job_id}",
      type: :ingestion_run,
      subtype: :ingestion,
      timestamp: event.inserted_at,
      state: event.state,
      job_id: event.oban_job_id,
      event: event,
      feed_provider: Map.get(feed, "origin_provider", "unknown"),
      feed_url: Map.get(feed, "url"),
      items: items,
      stats: %{
        processed: Map.get(details, "processed", 0),
        inserted: Map.get(details, "inserted", 0),
        seen: Map.get(details, "seen", 0),
        errors: Map.get(details, "errors", 0)
      }
    }
  end

  defp ranking_activity_runs(limit) do
    recent_runs =
      HomepageRankingDecision
      |> group_by([d], d.run_id)
      |> select([d], {d.run_id, max(d.inserted_at)})
      |> order_by([d], desc: max(d.inserted_at))
      |> limit(^limit)
      |> Repo.all()

    run_ids = Enum.map(recent_runs, fn {id, _} -> id end)
    timestamps = Map.new(recent_runs, fn {id, ts} -> {id, ts} end)

    if run_ids == [] do
      []
    else
      HomepageRankingDecision
      |> where([d], d.run_id in ^run_ids)
      |> order_by([d], asc: d.rank_position)
      |> preload([:permanent_article])
      |> Repo.all()
      |> Enum.group_by(& &1.run_id)
      |> Enum.map(fn {run_id, run_decisions} ->
        ts = Map.fetch!(timestamps, run_id)

        %{
          id: "ranking-#{run_id}",
          type: :ranking_refresh,
          subtype: :ranking,
          timestamp: ts,
          run_id: run_id,
          decisions: run_decisions,
          article_count: length(run_decisions)
        }
      end)
    end
  end
end
