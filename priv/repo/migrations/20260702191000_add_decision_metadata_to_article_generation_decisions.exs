defmodule LeythersCom.Repo.Migrations.AddDecisionMetadataToArticleGenerationDecisions do
  use Ecto.Migration

  def change do
    alter table(:article_generation_decisions) do
      add :decision_source, :string
      add :decision_confidence, :float
      add :fallback_reason, :text
    end

    create constraint(
             :article_generation_decisions,
             :article_generation_decisions_decision_source_check,
             check: "decision_source IS NULL OR decision_source IN ('llm', 'deterministic')"
           )

    create constraint(
             :article_generation_decisions,
             :article_generation_decisions_decision_confidence_check,
             check:
               "decision_confidence IS NULL OR (decision_confidence >= 0 AND decision_confidence <= 1)"
           )

    create index(:article_generation_decisions, [:decision_source])
  end
end
