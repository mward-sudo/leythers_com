defmodule LeythersCom.Intelligence.HomepageRankerOpenRouterFallbackTest do
  use ExUnit.Case, async: false

  alias LeythersCom.Content.PermanentArticle
  alias LeythersCom.Intelligence.HomepageRanker

  defmodule MissingKeyAdapter do
    @behaviour LeythersCom.Intelligence.LLMClient

    @impl true
    def generate(_prompt, _opts), do: {:error, :missing_openrouter_api_key}
  end

  setup do
    llm_original = Application.get_env(:leythers_com, :llm)

    on_exit(fn ->
      if llm_original do
        Application.put_env(:leythers_com, :llm, llm_original)
      else
        Application.delete_env(:leythers_com, :llm)
      end
    end)

    HomepageRanker.clear_cache!()
    :ok
  end

  test "falls back to deterministic importance when openrouter api key is missing" do
    Application.put_env(:leythers_com, :llm, adapter: MissingKeyAdapter)

    [ranked] =
      HomepageRanker.rank(
        [entry("Fallback story", DateTime.utc_now(), [1, 2])],
        llm_enabled: true,
        llm_candidate_limit: 1,
        recency_weight: 0.0,
        importance_weight: 1.0,
        llm_timeout_ms: 50
      )

    assert ranked.importance_source == :deterministic
    assert ranked.importance_score == 62
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
