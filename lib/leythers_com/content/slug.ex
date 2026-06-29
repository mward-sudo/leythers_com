defmodule LeythersCom.Content.Slug do
  import Ecto.Query

  alias LeythersCom.Repo
  alias LeythersCom.Content.PermanentArticle

  def generate(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
  end

  def unique_for_title(title) do
    base = generate(title)
    find_unique(base, 1)
  end

  defp find_unique(base, 1) do
    if taken?(base) do
      find_unique(base, 2)
    else
      {:ok, base}
    end
  end

  defp find_unique(base, n) do
    candidate = "#{base}-#{n}"

    if taken?(candidate) do
      find_unique(base, n + 1)
    else
      {:ok, candidate}
    end
  end

  defp taken?(slug) do
    Repo.exists?(from a in PermanentArticle, where: a.slug == ^slug)
  end
end
