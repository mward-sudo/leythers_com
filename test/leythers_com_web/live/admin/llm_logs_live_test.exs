defmodule LeythersComWeb.Admin.LLMLogsLiveTest do
  use LeythersComWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LeythersCom.Intelligence

  describe "authentication" do
    test "redirects unauthenticated users to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/llm-logs")
      assert path =~ "/users/log-in"
    end
  end

  describe "index" do
    setup :register_and_log_in_user

    test "renders paginated llm logs and shows selected detail", %{conn: conn} do
      for index <- 1..21 do
        {:ok, _log} =
          Intelligence.create_llm_interaction_log(%{
            adapter: "LeythersCom.Intelligence.LLMClient.Fake",
            model: "test-model",
            status: "ok",
            attempt: 1,
            prompt: "Prompt body #{String.pad_leading(to_string(index), 2, "0")}",
            context: %{"source" => %{"title" => "Leigh source #{index}"}},
            response_text: "Response body #{String.pad_leading(to_string(index), 2, "0")}",
            metadata: %{"purpose" => "admin_llm_log_test"}
          })
      end

      first_page = Intelligence.list_llm_interaction_logs(%{page: 1, per_page: 20})
      selected_log = List.last(first_page.entries)

      {:ok, view, html} = live(conn, ~p"/admin/llm-logs")

      assert html =~ "LLM Logs"
      assert has_element?(view, "#llm-log-list")
      assert has_element?(view, "#llm-log-detail")
      assert render(view) =~ "Page 1 of 2"

      view
      |> element("#llm-log-#{selected_log.id}")
      |> render_click()

      detail_html = render(view)
      assert detail_html =~ "Prompt"
      assert detail_html =~ "Context"
      assert detail_html =~ "Response"
      assert detail_html =~ selected_log.prompt
      assert detail_html =~ selected_log.response_text
      assert detail_html =~ selected_log.context["source"]["title"]

      next_html =
        view
        |> element("a", "Next")
        |> render_click()

      assert next_html =~ "Page 2 of 2"
    end
  end
end
