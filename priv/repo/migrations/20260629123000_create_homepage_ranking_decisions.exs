defmodule LeythersCom.Repo.Migrations.CreateHomepageRankingDecisions do
  use Ecto.Migration

  def change do
    create table(:homepage_ranking_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, :binary_id, null: false

      add :permanent_article_id,
          references(:permanent_articles, type: :binary_id, on_delete: :delete_all),
          null: false

      add :rank_position, :integer, null: false
      add :hybrid_score, :float, null: false
      add :importance_score, :integer, null: false
      add :recency_score, :float, null: false
      add :importance_source, :string, null: false, default: "deterministic"
      add :source_count, :integer, null: false, default: 0
      add :prompt_version, :string, null: false
      add :decision_summary, :text
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :estimated_cost_gbp, :decimal, null: false, default: 0.0, precision: 12, scale: 6

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:homepage_ranking_decisions, [:run_id])
    create index(:homepage_ranking_decisions, [:permanent_article_id])
    create unique_index(:homepage_ranking_decisions, [:run_id, :rank_position])

    create constraint(
             :homepage_ranking_decisions,
             :homepage_ranking_decisions_rank_position_check,
             check: "rank_position > 0"
           )

    create constraint(:homepage_ranking_decisions, :homepage_ranking_decisions_source_count_check,
             check: "source_count >= 0"
           )

    create constraint(
             :homepage_ranking_decisions,
             :homepage_ranking_decisions_importance_score_check,
             check: "importance_score >= 0 AND importance_score <= 100"
           )

    create constraint(
             :homepage_ranking_decisions,
             :homepage_ranking_decisions_recency_score_check,
             check: "recency_score >= 0 AND recency_score <= 100"
           )

    create constraint(:homepage_ranking_decisions, :homepage_ranking_decisions_hybrid_score_check,
             check: "hybrid_score >= 0 AND hybrid_score <= 100"
           )

    create constraint(
             :homepage_ranking_decisions,
             :homepage_ranking_decisions_importance_source_check,
             check: "importance_source IN ('deterministic', 'llm_generated', 'llm_cached')"
           )

    create constraint(:homepage_ranking_decisions, :homepage_ranking_decisions_input_tokens_check,
             check: "input_tokens >= 0"
           )

    create constraint(
             :homepage_ranking_decisions,
             :homepage_ranking_decisions_output_tokens_check,
             check: "output_tokens >= 0"
           )

    create constraint(
             :homepage_ranking_decisions,
             :homepage_ranking_decisions_estimated_cost_check,
             check: "estimated_cost_gbp >= 0"
           )
  end
end
