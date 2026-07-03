defmodule LeythersCom.Repo.Migrations.CreateLlmInteractionLogs do
  use Ecto.Migration

  def change do
    create table(:llm_interaction_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :adapter, :string, null: false
      add :model, :string
      add :status, :string, null: false
      add :attempt, :integer, null: false, default: 1
      add :prompt, :text, null: false
      add :context, :map, null: false, default: %{}
      add :response_text, :text
      add :error_summary, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:llm_interaction_logs, [:inserted_at])
    create index(:llm_interaction_logs, [:status])
    create index(:llm_interaction_logs, [:adapter])
    create index(:llm_interaction_logs, [:model])

    create constraint(:llm_interaction_logs, :llm_interaction_logs_status_check,
             check: "status IN ('ok', 'error')"
           )

    create constraint(:llm_interaction_logs, :llm_interaction_logs_attempt_check,
             check: "attempt >= 1"
           )
  end
end
