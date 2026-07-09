defmodule LeythersCom.Intelligence.HomepageRankingDecision do
  use Ecto.Schema
  import Ecto.Changeset

  alias LeythersCom.Content.PermanentArticle

  @valid_importance_sources ~w[deterministic llm_generated llm_cached]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "homepage_ranking_decisions" do
    field :run_id, Ecto.UUID
    field :rank_position, :integer
    field :hybrid_score, :float
    field :importance_score, :integer
    field :recency_score, :float
    field :importance_source, :string, default: "deterministic"
    field :source_count, :integer, default: 0
    field :prompt_version, :string
    field :decision_summary, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :estimated_cost_gbp, :decimal, default: Decimal.new("0")
    field :provider_input_tokens, :integer
    field :provider_output_tokens, :integer
    field :provider_total_tokens, :integer
    field :provider_cost, :decimal
    field :provider_cost_currency, :string

    belongs_to :permanent_article, PermanentArticle

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :run_id,
      :permanent_article_id,
      :rank_position,
      :hybrid_score,
      :importance_score,
      :recency_score,
      :importance_source,
      :source_count,
      :prompt_version,
      :decision_summary,
      :input_tokens,
      :output_tokens,
      :estimated_cost_gbp,
      :provider_input_tokens,
      :provider_output_tokens,
      :provider_total_tokens,
      :provider_cost,
      :provider_cost_currency
    ])
    |> validate_required([
      :run_id,
      :permanent_article_id,
      :rank_position,
      :hybrid_score,
      :importance_score,
      :recency_score,
      :importance_source,
      :source_count,
      :prompt_version
    ])
    |> validate_number(:rank_position, greater_than: 0)
    |> validate_number(:hybrid_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:importance_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:recency_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_inclusion(:importance_source, @valid_importance_sources)
    |> validate_number(:source_count, greater_than_or_equal_to: 0)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:estimated_cost_gbp, greater_than_or_equal_to: 0)
    |> validate_number(:provider_input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:provider_output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:provider_total_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:provider_cost, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:permanent_article_id)
    |> unique_constraint([:run_id, :rank_position])
  end
end
