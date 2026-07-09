defmodule LeythersCom.Repo.Migrations.AddEnrichmentLifecycleToRawSources do
  use Ecto.Migration

  def change do
    alter table(:raw_sources) do
      add :enrichment_status, :string, null: false, default: "queued"
      add :enrichment_failure_count, :integer, null: false, default: 0
      add :enrichment_failure_reason, :text
    end

    create index(:raw_sources, [:enrichment_status])

    create constraint(:raw_sources, :enrichment_status_values,
             check: "enrichment_status IN ('queued','in_progress','ready','failed')"
           )

    create constraint(:raw_sources, :enrichment_failure_count_non_negative,
             check: "enrichment_failure_count >= 0"
           )
  end
end
