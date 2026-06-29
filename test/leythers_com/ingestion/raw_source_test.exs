defmodule LeythersCom.Ingestion.RawSourceTest do
  use LeythersCom.DataCase, async: true

  alias Ecto.Changeset
  alias LeythersCom.Ingestion.RawSource

  @valid_attrs %{
    title: "Leigh Leopards secure top spot",
    url: "https://example.com/leigh-leopards-top-spot",
    origin_provider: "bbc_sport",
    external_published_at: ~U[2026-06-01 10:00:00.000000Z]
  }

  describe "changeset/2 with valid attributes" do
    test "returns a valid changeset" do
      assert %Changeset{valid?: true} = RawSource.changeset(%RawSource{}, @valid_attrs)
    end

    test "accepts an optional body_summary" do
      attrs = Map.put(@valid_attrs, :body_summary, "Short summary")
      assert %Changeset{valid?: true} = RawSource.changeset(%RawSource{}, attrs)
    end
  end

  describe "changeset/2 required fields" do
    test "rejects missing title" do
      attrs = Map.delete(@valid_attrs, :title)
      changeset = RawSource.changeset(%RawSource{}, attrs)
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing url" do
      attrs = Map.delete(@valid_attrs, :url)
      changeset = RawSource.changeset(%RawSource{}, attrs)
      assert %{url: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing origin_provider" do
      attrs = Map.delete(@valid_attrs, :origin_provider)
      changeset = RawSource.changeset(%RawSource{}, attrs)
      assert %{origin_provider: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing external_published_at" do
      attrs = Map.delete(@valid_attrs, :external_published_at)
      changeset = RawSource.changeset(%RawSource{}, attrs)
      assert %{external_published_at: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "changeset/2 status field" do
    test "defaults to pending" do
      changeset = RawSource.changeset(%RawSource{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :status) == "pending"
    end

    test "accepts valid status values" do
      for status <- ~w[pending processed ignored] do
        attrs = Map.put(@valid_attrs, :status, status)
        assert %Ecto.Changeset{valid?: true} = RawSource.changeset(%RawSource{}, attrs)
      end
    end

    test "rejects invalid status" do
      attrs = Map.put(@valid_attrs, :status, "unknown")
      changeset = RawSource.changeset(%RawSource{}, attrs)
      assert %{status: [_]} = errors_on(changeset)
    end
  end

  describe "changeset/2 last_check_status field" do
    test "accepts valid last_check_status values" do
      for status <- ~w[ok redirected broken] do
        attrs = Map.put(@valid_attrs, :last_check_status, status)
        assert %Ecto.Changeset{valid?: true} = RawSource.changeset(%RawSource{}, attrs)
      end
    end

    test "rejects invalid last_check_status" do
      attrs = Map.put(@valid_attrs, :last_check_status, "gone")
      changeset = RawSource.changeset(%RawSource{}, attrs)
      assert %{last_check_status: [_]} = errors_on(changeset)
    end

    test "allows nil last_check_status" do
      attrs = Map.put(@valid_attrs, :last_check_status, nil)
      assert %Changeset{valid?: true} = RawSource.changeset(%RawSource{}, attrs)
    end
  end
end
