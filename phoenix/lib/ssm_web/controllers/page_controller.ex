defmodule SsmWeb.PageController do
  use SsmWeb, :controller

  # Root is just a dispatcher: signed-in users land on the dashboard,
  # everyone else on the sign-in form.
  def home(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/dashboard")
    else
      redirect(conn, to: ~p"/sign-in")
    end
  end
end
