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

      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: date,
          input_tokens: 500,
          output_tokens: 100,
          estimated_cost_gbp: Decimal.new("0.000600")
        })

      {:ok, updated} =
        Intelligence.upsert_cost_ledger(%{
          date: date,
          input_tokens: 300,
          output_tokens: 50,
          estimated_cost_gbp: Decimal.new("0.000350")
        })

      assert updated.input_tokens == 800
      assert updated.output_tokens == 150
    end

    test "returns error changeset for missing date" do
      assert {:error, %Ecto.Changeset{}} = Intelligence.upsert_cost_ledger(%{})
    end
  end

  describe "monthly_spend/1" do
    test "returns sum of estimated_cost_gbp for a given year-month" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-01],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("3.000000")
        })

      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-02],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("2.500000")
        })

      total = Intelligence.monthly_spend(~D[2026-06-01])
      assert Decimal.equal?(total, Decimal.new("5.500000"))
    end

    test "returns zero for a month with no entries" do
      total = Intelligence.monthly_spend(~D[2025-01-01])
      assert Decimal.equal?(total, Decimal.new("0"))
    end
  end

  describe "monthly_budget_state/2" do
    test "returns under_budget below the warning threshold" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-01],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("20.00")
        })

      assert Intelligence.monthly_budget_state(~D[2026-06-01], Decimal.new("100.00")) ==
               :under_budget
    end

    test "returns near_budget at or above eighty percent of the cap" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-02],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("80.00")
        })

      assert Intelligence.monthly_budget_state(~D[2026-06-01], Decimal.new("100.00")) ==
               :near_budget
    end

    test "returns over_budget when the monthly spend meets the cap" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-03],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("100.00")
        })

      assert Intelligence.monthly_budget_state(~D[2026-06-01], Decimal.new("100.00")) ==
               :over_budget
    end
  end

  describe "monthly_generation_cap/0" do
    test "reads the configured default cap" do
      cap = Intelligence.monthly_generation_cap()
      assert Decimal.equal?(cap, Decimal.new("10.00"))
    end
  end

  describe "effective_monthly_cap/2" do
    test "uses the configured cap when no override is present" do
      cap = Intelligence.effective_monthly_cap(~D[2026-06-01], nil)
      assert Decimal.equal?(cap, Decimal.new("10.00"))
    end

    test "uses a valid month-end override to raise the cap" do
      override = %{monthly_cap_gbp: Decimal.new("15.00"), expires_on: ~D[2026-06-30]}
      cap = Intelligence.effective_monthly_cap(~D[2026-06-15], override)

      assert Decimal.equal?(cap, Decimal.new("15.00"))
    end

    test "ignores overrides that do not expire at month end" do
      override = %{monthly_cap_gbp: Decimal.new("15.00"), expires_on: ~D[2026-06-29]}
      cap = Intelligence.effective_monthly_cap(~D[2026-06-15], override)

      assert Decimal.equal?(cap, Decimal.new("10.00"))
    end
  end

  describe "generation_budget_state/2" do
    test "applies the effective cap before classifying spend" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-10],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("12.00")
        })

      override = %{monthly_cap_gbp: Decimal.new("15.00"), expires_on: ~D[2026-06-30]}

      assert Intelligence.generation_budget_state(~D[2026-06-01], override) == :near_budget
    end
  end

  describe "generation_allowed?/2" do
    test "returns true while the budget is still available" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-11],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("4.00")
        })

      assert Intelligence.generation_allowed?(~D[2026-06-01])
    end

    test "returns false when the budget is exceeded" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-12],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("10.00")
        })

      refute Intelligence.generation_allowed?(~D[2026-06-01])
    end
  end

  describe "ensure_generation_allowed!/2" do
    test "returns ok when generation is allowed" do
      assert :ok = Intelligence.ensure_generation_allowed!(~D[2026-06-01])
    end

    test "returns an over_budget error when generation is blocked" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-13],
          input_tokens: 0,
          output_tokens: 0,
          estimated_cost_gbp: Decimal.new("10.00")
        })

      assert {:error, :over_budget} = Intelligence.ensure_generation_allowed!(~D[2026-06-01])
    end
  end

  describe "recent_cost_ledgers/1" do
    test "returns most recent ledgers first and respects the limit" do
      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-08],
          input_tokens: 10,
          output_tokens: 5,
          estimated_cost_gbp: Decimal.new("1.00")
        })

      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-09],
          input_tokens: 20,
          output_tokens: 10,
          estimated_cost_gbp: Decimal.new("2.00")
        })

      {:ok, _} =
        Intelligence.upsert_cost_ledger(%{
          date: ~D[2026-06-10],
          input_tokens: 30,
          output_tokens: 15,
          estimated_cost_gbp: Decimal.new("3.00")
        })

      ledgers = Intelligence.recent_cost_ledgers(2)

      assert length(ledgers) == 2
      assert Enum.map(ledgers, & &1.date) == [~D[2026-06-10], ~D[2026-06-09]]
    end

    test "returns empty list for non-positive limits" do
      assert Intelligence.recent_cost_ledgers(0) == []
    end
  end
end
