defmodule LeythersComWeb.UserLive.Setup do
  use LeythersComWeb, :live_view

  alias LeythersCom.Accounts
  alias LeythersCom.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Create Admin User
            <:subtitle>
              Initialize your Leythers.com admin account
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="setup_form" phx-submit="save" phx-change="validate">
          <.input
            field={@form[:email]}
            type="email"
            label="Admin Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />

          <.button phx-disable-with="Creating admin..." class="btn btn-primary w-full">
            Create Admin User
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    # Redirect if users already exist
    if Accounts.users_exist?() do
      {:ok, redirect(socket, to: ~p"/users/log-in")}
    else
      changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)
      {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
    end
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.create_first_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Admin user created! An email was sent to #{user.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
