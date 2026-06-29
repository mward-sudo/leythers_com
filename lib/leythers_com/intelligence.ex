defmodule LeythersCom.Intelligence do
  @moduledoc false

  import Ecto.Query

  alias LeythersCom.Repo
  alias LeythersCom.Intelligence.CostLedger

  def upsert_cost_ledger(%{date: date} = attrs) when not is_nil(date) do
    changeset = CostLedger.changeset(%CostLedger{}, attrs)

    if changeset.valid? do
      Repo.transaction(fn -> do_upsert_ledger(changeset, date, attrs) end)
    else
      {:error, changeset}
    end
  end

  def upsert_cost_ledger(attrs) do
    {:error, CostLedger.changeset(%CostLedger{}, attrs)}
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
end
