defmodule LeythersCom.Repo.Migrations.AddProviderAccountingFields do
  use Ecto.Migration

  def change do
    alter table(:cost_ledgers) do
      add :provider_input_tokens, :integer, null: false, default: 0
      add :provider_output_tokens, :integer, null: false, default: 0
      add :provider_total_tokens, :integer, null: false, default: 0
      add :provider_cost, :decimal, null: false, default: "0.000000", precision: 12, scale: 6
      add :provider_cost_currency, :string, null: false, default: "credits"
    end

    create constraint(:cost_ledgers, :non_negative_provider_input_tokens,
             check: "provider_input_tokens >= 0"
           )

    create constraint(:cost_ledgers, :non_negative_provider_output_tokens,
             check: "provider_output_tokens >= 0"
           )

    create constraint(:cost_ledgers, :non_negative_provider_total_tokens,
             check: "provider_total_tokens >= 0"
           )

    create constraint(:cost_ledgers, :non_negative_provider_cost, check: "provider_cost >= 0")

    alter table(:article_generation_decisions) do
      add :provider_input_tokens, :integer
      add :provider_output_tokens, :integer
      add :provider_total_tokens, :integer
      add :provider_cost, :decimal, precision: 12, scale: 6
      add :provider_cost_currency, :string
    end

    create constraint(:article_generation_decisions, :provider_input_tokens_check,
             check: "provider_input_tokens IS NULL OR provider_input_tokens >= 0"
           )

    create constraint(:article_generation_decisions, :provider_output_tokens_check,
             check: "provider_output_tokens IS NULL OR provider_output_tokens >= 0"
           )

    create constraint(:article_generation_decisions, :provider_total_tokens_check,
             check: "provider_total_tokens IS NULL OR provider_total_tokens >= 0"
           )

    create constraint(:article_generation_decisions, :provider_cost_check,
             check: "provider_cost IS NULL OR provider_cost >= 0"
           )

    alter table(:homepage_ranking_decisions) do
      add :provider_input_tokens, :integer
      add :provider_output_tokens, :integer
      add :provider_total_tokens, :integer
      add :provider_cost, :decimal, precision: 12, scale: 6
      add :provider_cost_currency, :string
    end

    create constraint(:homepage_ranking_decisions, :provider_input_tokens_check,
             check: "provider_input_tokens IS NULL OR provider_input_tokens >= 0"
           )

    create constraint(:homepage_ranking_decisions, :provider_output_tokens_check,
             check: "provider_output_tokens IS NULL OR provider_output_tokens >= 0"
           )

    create constraint(:homepage_ranking_decisions, :provider_total_tokens_check,
             check: "provider_total_tokens IS NULL OR provider_total_tokens >= 0"
           )

    create constraint(:homepage_ranking_decisions, :provider_cost_check,
             check: "provider_cost IS NULL OR provider_cost >= 0"
           )
  end
end
