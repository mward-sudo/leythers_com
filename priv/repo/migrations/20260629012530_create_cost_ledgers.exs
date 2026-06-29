defmodule LeythersCom.Repo.Migrations.CreateCostLedgers do
  use Ecto.Migration

  def change do
    create table(:cost_ledgers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :date, :date, null: false
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :estimated_cost_gbp, :decimal, precision: 12, scale: 6, null: false, default: "0.000000"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cost_ledgers, [:date])

    create constraint(:cost_ledgers, :non_negative_input_tokens,
             check: "input_tokens >= 0")

    create constraint(:cost_ledgers, :non_negative_output_tokens,
             check: "output_tokens >= 0")

    create constraint(:cost_ledgers, :non_negative_cost,
             check: "estimated_cost_gbp >= 0")
  end
end
