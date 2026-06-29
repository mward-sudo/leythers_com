defmodule LeythersComWeb.PageController do
  use LeythersComWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
