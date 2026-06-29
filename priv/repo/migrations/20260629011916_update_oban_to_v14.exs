defmodule LeythersCom.Repo.Migrations.UpdateObanToV14 do
  @moduledoc """
  Upgrades the Oban schema to version 14.
  """

  use Ecto.Migration

  def up, do: Oban.Migrations.up(version: 14)
  def down, do: Oban.Migrations.down(version: 12)
end
