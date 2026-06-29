defmodule LeythersCom.Intelligence.JobEffectEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias LeythersCom.Content.PermanentArticle

  @valid_states ~w[available scheduled executing retryable completed discarded cancelled]

  @valid_actions ~w[
    created
    updated
    amalgamated
    skipped_budget
    skipped_publish_error
    skipped_validation
    no_op
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "job_effect_events" do
    field :oban_job_id, :integer
    field :worker, :string
    field :queue, :string
    field :state, :string
    field :attempt, :integer, default: 1
    field :decision_action, :string
    field :source_ids, {:array, Ecto.UUID}, default: []
    field :source_input_snapshot, :map, default: %{}
    field :change_summary, :string
    field :change_details, :map, default: %{}
    field :error_summary, :string
    field :process_run_id, Ecto.UUID
    field :llm_prompt, :string
    field :llm_output, :string

    belongs_to :permanent_article, PermanentArticle

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :oban_job_id,
      :worker,
      :queue,
      :state,
      :attempt,
      :decision_action,
      :permanent_article_id,
      :source_ids,
      :source_input_snapshot,
      :change_summary,
      :change_details,
      :error_summary
    ])
    |> validate_required([
      :oban_job_id,
      :worker,
      :queue,
      :state,
      :attempt,
      :decision_action,
      :source_ids,
      :source_input_snapshot,
      :change_details
    ])
    |> validate_inclusion(:state, @valid_states)
    |> validate_inclusion(:decision_action, @valid_actions)
    |> validate_number(:attempt, greater_than_or_equal_to: 1)
    |> foreign_key_constraint(:permanent_article_id)
  end
end
