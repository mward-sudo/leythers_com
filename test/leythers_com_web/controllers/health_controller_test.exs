defmodule LeythersComWeb.HealthControllerTest do
  use LeythersComWeb.ConnCase

  test "GET /health returns ok JSON", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert %{"status" => "ok", "checks" => %{"database" => "ok"}} = json_response(conn, 200)
  end
end
