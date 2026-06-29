defmodule LeythersCom.IntelligenceTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Intelligence
  alias LeythersCom.Intelligence.CostLedger

  describe "upsert_cost_ledger/1" do
    test "inserts a new ledger row for a date" do
      attrs = %{
        date: ~D[2026-06-01],
        input_tokens: 1000,
        output_tokens: 200,
        estimated_cost_gbp: Decimal.new("0.001200")
      }

      assert {:ok, %CostLedger{} = ledger} = Intelligence.upsert_cost_ledger(attrs)
      assert ledger.date == ~D[2026-06-01]
      assert ledger.input_tokens == 1000
    end

    test "accumulates tokens when called again for same date" do
      date = ~D[2026-06-02]
      {:ok, _} = Intelligence.upsert_cost_ledger(%{date: date, input_tokens: 500, output_tokens: 100, estimated_cost_gbp: Decimal.new("0.000600")})
      {:ok, updated} = Intelligence.upsert_cost_ledger(%{date: date, input_tokens: 300, output_tokens: 50, estimated_cost_gbp: Decimal.new("0.000350")})

      assert updated.input_tokens == 800
      assert updated.output_tokens == 150
    end

    test "returns error changeset for missing date" do
      assert {:error, %Ecto.Changeset{}} = Intelligence.upsert_cost_ledger(%{})
    end
  end

  describe "monthly_spend/1" do
    test "returns sum of estimated_cost_gbp for a given year-month" do
      {:ok, _} = Intelligence.upsert_cost_ledger(%{date: ~D[2026-06-01], input_tokens: 0, output_tokens: 0, estimated_cost_gbp: Decimal.new("3.000000")})
      {:ok, _} = Intelligence.upsert_cost_ledger(%{date: ~D[2026-06-02], input_tokens: 0, output_tokens: 0, estimated_cost_gbp: Decimal.new("2.500000")})

      total = Intelligence.monthly_spend(~D[2026-06-01])
      assert Decimal.equal?(total, Decimal.new("5.500000"))
    end

    test "returns zero for a month with no entries" do
      total = Intelligence.monthly_spend(~D[2025-01-01])
      assert Decimal.equal?(total, Decimal.new("0"))
    end
  end
end
