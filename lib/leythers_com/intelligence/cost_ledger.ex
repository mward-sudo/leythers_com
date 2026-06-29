defmodule LeythersCom.Intelligence.CostLedger do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "cost_ledgers" do
    field :date, :date
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :estimated_cost_gbp, :decimal, default: Decimal.new("0.000000")

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(cost_ledger, attrs) do
    cost_ledger
    |> cast(attrs, [:date, :input_tokens, :output_tokens, :estimated_cost_gbp])
    |> validate_required([:date])
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:estimated_cost_gbp, greater_than_or_equal_to: 0)
    |> unique_constraint(:date)
  end
end
