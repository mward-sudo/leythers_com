defmodule LeythersCom.Repo.Migrations.AddObanJobsTable do
  @moduledoc """
  Adds the Oban tables and indexes required for background job processing.
  """

  use Ecto.Migration

  def up, do: Oban.Migrations.up(version: 12)
  def down, do: Oban.Migrations.down(version: 1)
end
