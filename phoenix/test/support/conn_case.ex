defmodule SsmWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use SsmWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint SsmWeb.Endpoint

      use SsmWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import SsmWeb.ConnCase
    end
  end

  setup tags do
    Ssm.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @test_password "conn-case-test-pw"

  @doc "The password `setup_htpasswd/1` writes for the `admin` user."
  def test_password, do: @test_password

  @doc """
  Setup helper: points `:htpasswd_path` at a temp file holding an `admin`
  entry, restoring the previous config on exit.

      setup [:setup_htpasswd, :log_in]
  """
  def setup_htpasswd(_context) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ssm-test-htpasswd-#{System.unique_integer([:positive])}"
      )

    File.write!(path, "admin:" <> Bcrypt.hash_pwd_salt(@test_password) <> "\n")

    previous = Application.get_env(:ssm, :htpasswd_path)
    Application.put_env(:ssm, :htpasswd_path, path)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ssm, :htpasswd_path, previous)
      File.rm(path)
    end)

    %{htpasswd: path}
  end

  @doc "Setup helper: seeds the session so `conn` is signed in as `admin`."
  def log_in(%{conn: conn}) do
    %{conn: log_in_user(conn, "admin")}
  end

  @doc "Signs `conn` in as `username` (entry must exist in the htpasswd file)."
  def log_in_user(conn, username) do
    path = Application.get_env(:ssm, :htpasswd_path)
    {:ok, fingerprint} = Ssm.Auth.Htpasswd.entry_fingerprint(path, username)

    Plug.Test.init_test_session(conn, %{
      ssm_user: username,
      pwv: fingerprint,
      logged_in_at: System.os_time(:second),
      live_socket_id: "ssm_sessions:" <> Base.url_encode64(username)
    })
  end
end
