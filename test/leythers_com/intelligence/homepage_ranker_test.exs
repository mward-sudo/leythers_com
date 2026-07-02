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

  test "raises when importance generation times out" do
    blocking_generator = fn _entry ->
      receive do
        :never -> :ok
      end
    end

    assert_raise RuntimeError, ~r/^llm_unavailable:/, fn ->
      HomepageRanker.rank(
        [entry("Slow", DateTime.utc_now(), [1, 2])],
        llm_enabled: true,
        llm_candidate_limit: 1,
        llm_timeout_ms: 10,
        importance_generator: blocking_generator
      )
    end
  end

  test "prioritizes source publication timestamp for recency scoring" do
    now = DateTime.utc_now()

    article_with_newer_source =
      entry("New source", DateTime.add(now, -24 * 3600, :second), [])
      |> put_in([:sources], [%{external_published_at: DateTime.add(now, -60, :second)}])

    article_with_older_source =
      entry("Old source", now, [])
      |> put_in([:sources], [%{external_published_at: DateTime.add(now, -12 * 3600, :second)}])

    ranked =
      HomepageRanker.rank([article_with_older_source, article_with_newer_source],
        llm_enabled: false,
        recency_weight: 0.7,
        importance_weight: 0.3
      )

    assert hd(ranked).article.title == "New source"
  end

  test "keeps near-duplicate stories by title similarity" do
    now = DateTime.utc_now()

    newer =
      entry("Leopards sign Melbourne Storm prop for 2026", now, [%{id: "a-1"}])

    older =
      entry(
        "Leopards land Melbourne prop signing from Storm",
        DateTime.add(now, -30 * 60, :second),
        [%{id: "b-1"}]
      )

    ranked =
      HomepageRanker.rank([older, newer],
        llm_enabled: false,
        recency_weight: 0.7,
        importance_weight: 0.3
      )

    assert length(ranked) == 2
    assert hd(ranked).article.title == "Leopards sign Melbourne Storm prop for 2026"
  end

  test "keeps duplicates even when source overlap exists" do
    now = DateTime.utc_now()

    first =
      entry("Leigh edge rivals in thriller", now, [%{raw_source_id: "shared-source"}])

    second =
      entry(
        "Another angle on the same match result",
        DateTime.add(now, -15 * 60, :second),
        [%{raw_source_id: "shared-source"}]
      )

    ranked =
      HomepageRanker.rank([second, first],
        llm_enabled: false,
        recency_weight: 0.7,
        importance_weight: 0.3
      )

    assert length(ranked) == 2
    assert hd(ranked).article.title == "Leigh edge rivals in thriller"
  end

  test "keeps near-duplicate stories by article text similarity" do
    now = DateTime.utc_now()

    first =
      entry("Different headline one", now, [%{id: "t-1"}])
      |> Map.update!(:article, fn article ->
        %{article | body: "Leigh sign Melbourne Storm prop after transfer talks"}
      end)

    second =
      entry("Different headline two", DateTime.add(now, -10 * 60, :second), [%{id: "t-2"}])
      |> Map.update!(:article, fn article ->
        %{article | body: "Transfer talks end with Leigh signing Melbourne Storm prop"}
      end)

    ranked =
      HomepageRanker.rank([second, first],
        llm_enabled: false,
        recency_weight: 0.7,
        importance_weight: 0.3
      )

    assert length(ranked) == 2
    assert hd(ranked).article.title == "Different headline one"
  end

  test "keeps paraphrased duplicates with strong shared entity tokens" do
    now = DateTime.utc_now()

    first =
      entry("Vaalepu power boost for Leopards", now, [
        %{id: "p-1", title: "Leigh sign Melbourne prop Vaalepu"}
      ])
      |> Map.update!(:article, fn article ->
        %{article | body: "Leigh sign Melbourne Storm prop Lazarus Vaalepu for run-in"}
      end)

    second =
      entry("Leopards land a mammoth middle", DateTime.add(now, -10 * 60, :second), [
        %{id: "p-2", title: "Melbourne prop Lazarus Vaalepu joins Leigh"}
      ])
      |> Map.update!(:article, fn article ->
        %{article | body: "Lazarus Vaalepu gives Leigh a Melbourne prop injection in the middle"}
      end)

    ranked =
      HomepageRanker.rank([second, first],
        llm_enabled: false,
        recency_weight: 0.7,
        importance_weight: 0.3
      )

    assert length(ranked) == 2
    assert hd(ranked).article.title == "Vaalepu power boost for Leopards"
  end

  test "downranks generic boilerplate copy even when newer" do
    now = DateTime.utc_now()

    generic_newer =
      entry("Leigh Leopards' Current Performance and Upcoming Matches", now, [%{id: "g-1"}])
      |> Map.update!(:article, fn article ->
        %{
          article
          | summary:
              "Leigh Leopards are looking to make a statement and are in impressive form lately.",
            body: "The game should be a closely contested one with a lot to play for."
        }
      end)

    specific_older =
      entry(
        "Leigh confirm Vaalepu arrival before Toulouse trip",
        DateTime.add(now, -15 * 60, :second),
        [%{id: "s-1"}]
      )
      |> Map.update!(:article, fn article ->
        %{
          article
          | summary:
              "Leigh have completed a mid-season prop signing to boost middle rotation depth.",
            body: "Club details point to an immediate squad role for the Toulouse fixture."
        }
      end)

    ranked =
      HomepageRanker.rank([generic_newer, specific_older],
        llm_enabled: false,
        generic_boilerplate_penalty_max: 30.0
      )

    assert hd(ranked).article.title == "Leigh confirm Vaalepu arrival before Toulouse trip"
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
