defmodule LeythersCom.Intelligence.CostLedgerTest do
  use LeythersCom.DataCase, async: true

  alias Ecto.Changeset
  alias LeythersCom.Intelligence.CostLedger

  @valid_attrs %{
    date: ~D[2026-06-01]
  }

  describe "changeset/2 with valid attributes" do
    test "returns a valid changeset" do
      assert %Changeset{valid?: true} = CostLedger.changeset(%CostLedger{}, @valid_attrs)
    end

    test "accepts explicit token and cost values" do
      attrs =
        Map.merge(@valid_attrs, %{
          input_tokens: 1000,
          output_tokens: 500,
          estimated_cost_gbp: Decimal.new("0.003000")
        })

      assert %Changeset{valid?: true} = CostLedger.changeset(%CostLedger{}, attrs)
    end
  end

  describe "changeset/2 required fields" do
    test "rejects missing date" do
      changeset = CostLedger.changeset(%CostLedger{}, %{})
      assert %{date: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "changeset/2 numeric constraints" do
    test "rejects negative input_tokens" do
      attrs = Map.put(@valid_attrs, :input_tokens, -1)
      changeset = CostLedger.changeset(%CostLedger{}, attrs)
      assert %{input_tokens: [_]} = errors_on(changeset)
    end

    test "rejects negative output_tokens" do
      attrs = Map.put(@valid_attrs, :output_tokens, -1)
      changeset = CostLedger.changeset(%CostLedger{}, attrs)
      assert %{output_tokens: [_]} = errors_on(changeset)
    end

    test "rejects negative estimated_cost_gbp" do
      attrs = Map.put(@valid_attrs, :estimated_cost_gbp, Decimal.new("-0.000001"))
      changeset = CostLedger.changeset(%CostLedger{}, attrs)
      assert %{estimated_cost_gbp: [_]} = errors_on(changeset)
    end
  end

  describe "changeset/2 defaults" do
    test "input_tokens defaults to 0" do
      changeset = CostLedger.changeset(%CostLedger{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :input_tokens) == 0
    end

    test "output_tokens defaults to 0" do
      changeset = CostLedger.changeset(%CostLedger{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :output_tokens) == 0
    end
  end
end
