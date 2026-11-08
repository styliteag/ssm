defmodule SsmWeb.Api.InputValidationApiTest do
  @moduledoc """
  Text that ends up in authorized_keys (key comments, logins, options) or in
  audit lines must not carry control characters; options are allow-listed.
  Failures are the stable 422 `VALIDATION_FAILED`.
  """

  use SsmWeb.ConnCase, async: false

  import Ssm.Fixtures

  alias Ssm.Auth.Token

  setup %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer " <> Token.issue_access("admin"))
    {:ok, conn: conn}
  end

  defp assert_422(conn, field) do
    body = json_response(conn, 422)
    assert body["success"] == false
    assert body["error"]["code"] == "VALIDATION_FAILED"
    assert Enum.any?(body["error"]["details"]["errors"], &(&1["field"] == field)), inspect(body)
    body
  end

  describe "authorization options" do
    test "an unknown option is 422 on create", %{conn: conn} do
      attrs = %{
        "host_id" => host_fixture().id,
        "user_id" => user_fixture().id,
        "login" => "deploy",
        "options" => "no-pty,bogus"
      }

      body = conn |> post(~p"/api/v2/authorizations", attrs) |> assert_422("options")
      assert inspect(body["error"]["details"]) =~ "unknown option"
    end

    test "a newline in the options is 422 on update", %{conn: conn} do
      auth = authorization_fixture(user_fixture(), host_fixture())

      conn
      |> patch(~p"/api/v2/authorizations/#{auth.id}", %{
        "options" => "no-pty\nssh-ed25519 AAAAEVIL x"
      })
      |> assert_422("options")
    end

    test "valid options are stored", %{conn: conn} do
      attrs = %{
        "host_id" => host_fixture().id,
        "user_id" => user_fixture().id,
        "login" => "deploy",
        "options" => ~s(no-pty,from="10.0.0.0/8")
      }

      body = conn |> post(~p"/api/v2/authorizations", attrs) |> json_response(201)
      assert body["data"]["options"] == ~s(no-pty,from="10.0.0.0/8")
    end
  end

  describe "control characters" do
    test "in a key name is 422 on create and update", %{conn: conn} do
      user = user_fixture()

      conn
      |> post(~p"/api/v2/keys", %{
        "user_id" => user.id,
        "key_type" => "ssh-ed25519",
        "key_base64" => "AAAAC3NzaC1lZDI1NTE5AAAAIControl",
        "name" => "laptop\nssh-ed25519 AAAAINJECTED evil"
      })
      |> assert_422("name")

      key = key_fixture(user)

      conn
      |> patch(~p"/api/v2/keys/#{key.id}", %{"extra_comment" => "x\ry"})
      |> assert_422("extra_comment")
    end

    test "in a username is 422", %{conn: conn} do
      conn |> post(~p"/api/v2/users", %{"username" => "bob\n"}) |> assert_422("username")
    end

    test "in an authorization login or comment is 422", %{conn: conn} do
      base = %{"host_id" => host_fixture().id, "user_id" => user_fixture().id}

      conn
      |> post(~p"/api/v2/authorizations", Map.put(base, "login", "deploy\nroot"))
      |> assert_422("login")

      conn
      |> post(
        ~p"/api/v2/authorizations",
        Map.merge(base, %{"login" => "deploy", "comment" => "a\u0007b"})
      )
      |> assert_422("comment")
    end
  end
end
