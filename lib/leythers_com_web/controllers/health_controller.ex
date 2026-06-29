defmodule LeythersComWeb.HealthController do
  use LeythersComWeb, :controller

  alias LeythersCom.Repo

  def show(conn, _params) do
    case Repo.query("SELECT 1") do
      {:ok, _result} ->
        json(conn, %{status: "ok", checks: %{database: "ok"}})

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "degraded", checks: %{database: "error"}})
    end
  end
end
