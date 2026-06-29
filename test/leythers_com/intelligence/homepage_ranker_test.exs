defmodule LeythersCom.Intelligence.HomepageRankerTest do
  use ExUnit.Case, async: true

  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Intelligence.HomepageRanker

  setup do
    HomepageRanker.clear_cache!()
    :ok
  end

  test "ranks newer stories higher when llm is disabled" do
    now = DateTime.utc_now()

    newest =
      entry("Newest", DateTime.add(now, -30 * 60, :second), [1, 2, 3])

    older =
      entry("Older", DateTime.add(now, -8 * 3600, :second), [1])

    ranked =
      HomepageRanker.rank([older, newest],
        llm_enabled: false,
        recency_weight: 0.7,
        importance_weight: 0.3
      )

    assert hd(ranked).article.title == "Newest"
  end

  test "limits llm importance generation to top candidates and uses cache" do
    parent = self()

    generator = fn _entry ->
      send(parent, :importance_called)
      88
    end

    entries = [
      entry("A", DateTime.utc_now(), []),
      entry("B", DateTime.add(DateTime.utc_now(), -3600, :second), []),
      entry("C", DateTime.add(DateTime.utc_now(), -7200, :second), [])
    ]

    _ =
      HomepageRanker.rank(entries,
        llm_enabled: true,
        llm_candidate_limit: 1,
        llm_cooldown_seconds: 3600,
        importance_generator: generator
      )

    _ =
      HomepageRanker.rank(entries,
        llm_enabled: true,
        llm_candidate_limit: 1,
        llm_cooldown_seconds: 3600,
        importance_generator: generator
      )

    assert_receive :importance_called
    refute_receive :importance_called
  end

  test "falls back to deterministic scoring when importance generation times out" do
    blocking_generator = fn _entry ->
      receive do
        :never -> :ok
      end
    end

    [ranked_entry] =
      HomepageRanker.rank(
        [entry("Slow", DateTime.utc_now(), [1, 2])],
        llm_enabled: true,
        llm_candidate_limit: 1,
        llm_timeout_ms: 10,
        importance_generator: blocking_generator
      )

    assert ranked_entry.importance_source == :deterministic
    assert ranked_entry.importance_score == 70
  end

  defp entry(title, timestamp, source_markers) do
    %{
      article: %PermanentArticle{
        id: Ecto.UUID.generate(),
        title: title,
        body: "Body",
        slug: String.downcase(title),
        author_type: "ai_editor",
        status: "published",
        version: 1,
        inserted_at: timestamp,
        updated_at: timestamp
      },
      sources: source_markers
    }
  end
end
