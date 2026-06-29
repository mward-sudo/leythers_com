defmodule LeythersCom.Intelligence.ArticleGenerationDecision do
  use Ecto.Schema
  import Ecto.Changeset

  alias LeythersCom.Content.PermanentArticle

  @valid_actions ~w[created updated skipped_budget skipped_publish_error]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "article_generation_decisions" do
    field :run_id, Ecto.UUID
    field :decision_action, :string
    field :source_ids, {:array, Ecto.UUID}, default: []
    field :source_count, :integer, default: 0
    field :significance_score, :integer, default: 0
    field :significance_threshold, :integer, default: 0
    field :prompt_version, :string
    field :decision_summary, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :estimated_cost_gbp, :decimal, default: Decimal.new("0")

    belongs_to :permanent_article, PermanentArticle

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :run_id,
      :decision_action,
      :source_ids,
      :source_count,
      :significance_score,
      :significance_threshold,
      :prompt_version,
      :decision_summary,
      :input_tokens,
      :output_tokens,
      :estimated_cost_gbp,
      :permanent_article_id
    ])
    |> validate_required([
      :run_id,
      :decision_action,
      :source_ids,
      :source_count,
      :significance_score,
      :significance_threshold,
      :prompt_version
    ])
    |> validate_inclusion(:decision_action, @valid_actions)
    |> validate_number(:source_count, greater_than_or_equal_to: 0)
    |> validate_number(:significance_score,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_number(:significance_threshold,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:estimated_cost_gbp, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:permanent_article_id)
  end
end
