defmodule LeythersCom.Intelligence.SourceClustererTest do
  use ExUnit.Case, async: true

  alias LeythersCom.Intelligence.SourceClusterer

  test "clusters obvious same-story sources without LLM" do
    sources = [
      %{
        id: "s1",
        title: "Leigh beat Toulouse in dramatic finish",
        content:
          "Leigh beat Toulouse late after a dramatic final ten minutes and strong middle defence.",
        body_summary: "Leigh edge Toulouse in dramatic finish"
      },
      %{
        id: "s2",
        title: "Dramatic finish sees Leigh beat Toulouse",
        content:
          "A dramatic final period saw Leigh beat Toulouse with strong middle defence and kick chase.",
        body_summary: "Leigh beat Toulouse after late push"
      },
      %{
        id: "s3",
        title: "Wigan preview team news ahead of derby",
        content: "Wigan release team news ahead of derby with likely rotation.",
        body_summary: "Wigan preview"
      }
    ]

    clusters =
      SourceClusterer.cluster_by_topic(sources,
        llm_enabled: false,
        llm_max_comparisons: 0
      )

    cluster_sizes = clusters |> Enum.map(&length/1) |> Enum.sort()
    assert cluster_sizes == [1, 2]
  end

  test "limits borderline LLM similarity checks per batch" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    classifier = fn _source_a, _source_b ->
      Agent.update(counter, &(&1 + 1))
      false
    end

    sources = [
      %{id: "a", title: "Leigh note one", content: "short content alpha", body_summary: "alpha"},
      %{id: "b", title: "Leigh note two", content: "short content beta", body_summary: "beta"},
      %{id: "c", title: "Leigh note three", content: "short content gamma", body_summary: "gamma"}
    ]

    _clusters =
      SourceClusterer.cluster_by_topic(sources,
        llm_enabled: true,
        llm_max_comparisons: 1,
        deterministic_merge_threshold: 1.0,
        deterministic_reject_threshold: 0.0,
        similarity_classifier: classifier
      )

    assert Agent.get(counter, & &1) == 1
  end
end
