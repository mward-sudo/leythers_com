defmodule LeythersCom.Repo.Migrations.AddLlmAndProcessRunFieldsToJobEffectEvents do
  use Ecto.Migration

  def change do
    alter table(:job_effect_events) do
      add :process_run_id, :binary_id
      add :llm_prompt, :text
      add :llm_output, :text
    end

    create index(:job_effect_events, [:process_run_id])
  end
end
