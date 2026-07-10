defmodule LeythersCom.Content.AIEditorialTest do
  use LeythersCom.DataCase, async: true

  alias LeythersCom.Content
  alias LeythersCom.Content.ArticleSource
  alias LeythersCom.Ingestion

  describe "publish_or_update_ai_article/3" do
    test "creates a new ai article with voice styling and rumour labeling" do
      source_id = create_source_id!("Leigh linked source", "https://example.com/ai-linked-source")

      assert {:ok, :created, article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh linked with surprise halfback",
                   body: "Reports suggest Leigh are exploring a move."
                 },
                 [source_id],
                 rumour: true
               )

      assert article.author_type == "ai_editor"
      assert String.starts_with?(article.title, "Rumour: ")
      assert article.body =~ "Rumour mill warning"
      refute article.body =~ "Terrace verdict"
    end

    test "updates recent matching ai article when change is not significant" do
      source_id = create_source_id!("Leigh update source", "https://example.com/ai-update-source")

      assert {:ok, :created, created_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh eye cup final boost",
                   body: "Initial version"
                 },
                 [source_id]
               )

      assert {:ok, :updated, updated_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh eye cup final boost as squad improves",
                   body: "Updated version"
                 },
                 [source_id]
               )

      assert updated_article.id == created_article.id
      assert updated_article.version == created_article.version + 1
      assert updated_article.body =~ "Updated version"
    end

    test "updates recent matching ai article for similar titles with different leading tokens" do
      source_id_one =
        create_source_id!(
          "Leigh Toulouse source one",
          "https://example.com/ai-similar-title-source-1"
        )

      source_id_two =
        create_source_id!(
          "Leigh Toulouse source two",
          "https://example.com/ai-similar-title-source-2"
        )

      assert {:ok, :created, created_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Super League: Leigh overcome Toulouse as Charnley scores four tries",
                   body: "Initial version"
                 },
                 [source_id_one]
               )

      assert {:ok, :updated, updated_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Charnley scores four tries as Leigh beat Toulouse",
                   body: "Updated version"
                 },
                 [source_id_two]
               )

      assert updated_article.id == created_article.id
      assert updated_article.version == created_article.version + 1
      assert count_article_sources(updated_article.id) == 2
    end

    test "updates same ai article for similar Charnley contract and playing future titles" do
      source_id_one =
        create_source_id!(
          "Charnley contract source",
          "https://example.com/ai-charnley-contract-source"
        )

      source_id_two =
        create_source_id!(
          "Charnley future source",
          "https://example.com/ai-charnley-future-source"
        )

      assert {:ok, :created, created_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title:
                     "Josh Charnley drops major contract hint as Leigh Leopards star confirms intentions to go round again",
                   body: "Initial contract hint version"
                 },
                 [source_id_one]
               )

      assert {:ok, :updated, updated_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title:
                     "Josh Charnley sends message to Leigh Leopards on playing future - Love Rugby League",
                   body: "Updated playing future version"
                 },
                 [source_id_two]
               )

      assert updated_article.id == created_article.id
      assert updated_article.version == created_article.version + 1
      assert count_article_sources(updated_article.id) == 2
    end

    test "creates a new ai article when change is significant and story is different" do
      source_id_one =
        create_source_id!("Leigh significant source", "https://example.com/ai-significant-source")

      source_id_two =
        create_source_id!(
          "Leigh academy source",
          "https://example.com/ai-significant-source-different-story"
        )

      assert {:ok, :created, first_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh set for another big night",
                   body: "Base story"
                 },
                 [source_id_one]
               )

      assert {:ok, :created, second_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh academy prospects shine in reserve clash",
                   body: "Significant shift"
                 },
                 [source_id_two],
                 significant_change: true
               )

      refute second_article.id == first_article.id
      assert second_article.version == 1
    end

    test "updates recent matching ai article even when change is significant" do
      source_id =
        create_source_id!(
          "Leigh significant update source",
          "https://example.com/ai-significant-update-source"
        )

      assert {:ok, :created, first_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh set for another big night",
                   body: "Base story"
                 },
                 [source_id]
               )

      assert {:ok, :updated, second_article} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh set for another big night with transfer twist",
                   body: "Significant update on same story"
                 },
                 [source_id],
                 significant_change: true
               )

      assert second_article.id == first_article.id
      assert second_article.version == first_article.version + 1
    end

    test "returns error when ai article has no source links" do
      assert {:error, :source_ids_required} =
               Content.publish_or_update_ai_article(
                 %{
                   title: "Leigh unsupported source-less AI story",
                   body: "This should fail because source ids are required."
                 },
                 []
               )
    end
  end

  defp create_source_id!(title, url) do
    {:ok, source} =
      Ingestion.create_raw_source(%{
        title: title,
        url: url,
        origin_provider: "test_feed",
        external_published_at: DateTime.utc_now()
      })

    source.id
  end

  defp count_article_sources(article_id) do
    ArticleSource
    |> where([article_source], article_source.permanent_article_id == ^article_id)
    |> Repo.aggregate(:count, :id)
  end
end
