defmodule LeythersCom.Repo.Migrations.CreateJobEffectEvents do
  use Ecto.Migration

  def change do
    create table(:job_effect_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :oban_job_id, :bigint, null: false
      add :worker, :string, null: false
      add :queue, :string, null: false
      add :state, :string, null: false
      add :attempt, :integer, null: false, default: 1
      add :decision_action, :string, null: false

      add :permanent_article_id,
          references(:permanent_articles, type: :binary_id, on_delete: :nilify_all)

      add :source_ids, {:array, :uuid}, null: false, default: []
      add :source_input_snapshot, :map, null: false, default: %{}
      add :change_summary, :text
      add :change_details, :map, null: false, default: %{}
      add :error_summary, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:job_effect_events, [:oban_job_id])
    create index(:job_effect_events, [:state])
    create index(:job_effect_events, [:worker])
    create index(:job_effect_events, [:inserted_at])

    create constraint(:job_effect_events, :job_effect_events_state_check,
             check:
               "state IN ('available', 'scheduled', 'executing', 'retryable', 'completed', 'discarded', 'cancelled')"
           )

    create constraint(:job_effect_events, :job_effect_events_decision_action_check,
             check:
               "decision_action IN ('created', 'updated', 'amalgamated', 'skipped_budget', 'skipped_publish_error', 'skipped_validation', 'no_op')"
           )

    create constraint(:job_effect_events, :job_effect_events_attempt_check, check: "attempt >= 1")
  end
end
