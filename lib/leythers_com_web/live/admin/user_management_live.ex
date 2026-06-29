defmodule LeythersComWeb.Admin.UserManagementLive do
  use LeythersComWeb, :live_view

  alias LeythersCom.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <div>
          <.header>
            User Management
            <:subtitle>Manage system users and admin privileges</:subtitle>
          </.header>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-zebra w-full">
            <thead>
              <tr>
                <th>Email</th>
                <th>Role</th>
                <th>Confirmed</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for user <- @users do %>
                <tr>
                  <td>{user.email}</td>
                  <td>
                    <span class={[
                      "badge",
                      user.is_admin && "badge-primary",
                      !user.is_admin && "badge-ghost"
                    ]}>
                      {if user.is_admin, do: "Admin", else: "User"}
                    </span>
                  </td>
                  <td>
                    {if user.confirmed_at,
                      do: "✓ #{format_datetime(user.confirmed_at)}",
                      else: "Pending"}
                  </td>
                  <td>
                    <div class="space-x-2 flex">
                      <%= if user.is_admin && Enum.count(@users, & &1.is_admin) == 1 do %>
                        <button
                          disabled
                          class="btn btn-sm btn-ghost"
                          title="Cannot revoke admin from last admin user"
                        >
                          Toggle Admin
                        </button>
                      <% else %>
                        <button
                          phx-click="toggle_admin"
                          phx-value-user-id={user.id}
                          class="btn btn-sm btn-ghost"
                        >
                          {if user.is_admin, do: "Revoke Admin", else: "Grant Admin"}
                        </button>
                      <% end %>
                      <%= if user.id != @current_scope.user.id do %>
                        <button
                          phx-click="delete_user"
                          phx-value-user-id={user.id}
                          data-confirm="Are you sure you want to delete this user? This action cannot be undone."
                          class="btn btn-sm btn-error"
                        >
                          Delete
                        </button>
                      <% else %>
                        <button
                          disabled
                          class="btn btn-sm btn-ghost"
                          title="Cannot delete your own account here"
                        >
                          Delete
                        </button>
                      <% end %>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

        <%= if Enum.empty?(@users) do %>
          <div class="text-center text-gray-500">
            <p>No users yet</p>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    users = Accounts.list_users()
    {:ok, assign(socket, users: users)}
  end

  @impl true
  def handle_event("toggle_admin", %{"user-id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)

    case Accounts.update_user_admin(user, !user.is_admin) do
      {:ok, _updated_user} ->
        users = Accounts.list_users()

        {:noreply,
         socket
         |> assign(users: users)
         |> put_flash(
           :info,
           "User #{user.email} admin status updated"
         )}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update user admin status")}
    end
  end

  def handle_event("delete_user", %{"user-id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)

    case Accounts.delete_user(user) do
      {:ok, _deleted_user} ->
        users = Accounts.list_users()

        {:noreply,
         socket
         |> assign(users: users)
         |> put_flash(:info, "User #{user.email} deleted")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete user")}
    end
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(_), do: "-"
end
