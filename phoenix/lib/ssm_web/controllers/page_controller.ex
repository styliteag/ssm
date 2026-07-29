defmodule SsmWeb.PageController do
  use SsmWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
