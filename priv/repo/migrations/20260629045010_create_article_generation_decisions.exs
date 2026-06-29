defmodule LeythersCom.Repo.Migrations.CreateArticleGenerationDecisions do
  use Ecto.Migration

  def change do
    create table(:article_generation_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, :binary_id, null: false
      add :decision_action, :string, null: false
      add :source_ids, {:array, :binary_id}, null: false, default: []
      add :source_count, :integer, null: false, default: 0
      add :significance_score, :integer, null: false, default: 0
      add :significance_threshold, :integer, null: false, default: 0
      add :prompt_version, :string, null: false
      add :decision_summary, :text
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :estimated_cost_gbp, :decimal, null: false, default: 0.0, precision: 12, scale: 6

      add :permanent_article_id,
          references(:permanent_articles, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:article_generation_decisions, [:run_id])
    create index(:article_generation_decisions, [:permanent_article_id])
    create index(:article_generation_decisions, [:inserted_at])

    create constraint(
             :article_generation_decisions,
             :article_generation_decisions_action_check,
             check:
               "decision_action IN ('created', 'updated', 'skipped_budget', 'skipped_publish_error')"
           )

    create constraint(
             :article_generation_decisions,
             :article_generation_decisions_source_count_check,
             check: "source_count >= 0"
           )

    create constraint(
             :article_generation_decisions,
             :article_generation_decisions_significance_score_check,
             check: "significance_score >= 0 AND significance_score <= 100"
           )

    create constraint(
             :article_generation_decisions,
             :article_generation_decisions_significance_threshold_check,
             check: "significance_threshold >= 0 AND significance_threshold <= 100"
           )

    create constraint(
             :article_generation_decisions,
             :article_generation_decisions_input_tokens_check,
             check: "input_tokens >= 0"
           )

    create constraint(
             :article_generation_decisions,
             :article_generation_decisions_output_tokens_check,
             check: "output_tokens >= 0"
           )

    create constraint(
             :article_generation_decisions,
             :article_generation_decisions_estimated_cost_check,
             check: "estimated_cost_gbp >= 0"
           )
  end
end
