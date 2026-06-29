defmodule LeythersCom.Intelligence do
  @moduledoc """
  Intelligence context for daily cost ledger upserts and monthly spend queries.
  """

  import Ecto.Query

  alias LeythersCom.Intelligence.CostLedger
  alias LeythersCom.Repo
  alias Oban.Job

  @budget_config_key :intelligence_budget

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

  defp normalize_budget_result(:ok), do: :ok
  defp normalize_budget_result({:ok, _}), do: :ok
  defp normalize_budget_result(_), do: :error
end
