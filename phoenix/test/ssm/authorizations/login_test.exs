defmodule Ssm.Authorizations.LoginTest do
  @moduledoc """
  The remote login of an authorization or grant must be a POSIX-style user
  name (`Ssm.Authorizations.Login`) when it is set or changed. Rows already
  stored with another login (legacy data) stay usable: a change that keeps
  the login and the copies made by split/merge are not checked.
  """

  use Ssm.DataCase

  import Ssm.Fixtures

  alias Ssm.Authorizations
  alias Ssm.Authorizations.{Authorization, Login}
  alias Ssm.Grants.Grant
  alias Ssm.Repo
  alias Ssm.Users.BulkOps

  @valid ~w(deploy root a _svc Administrator infectopharm.com fail2ban-qa web_dev01 machine$) ++
           [String.duplicate("a", 32)]

  @invalid [
    "",
    "-oProxyCommand=x",
    "-",
    "1234",
    "0",
    "9user",
    ".hidden",
    "a b",
    "user@corp.example",
    "CORP\\user",
    "../etc",
    "a/b",
    "x$y",
    "$",
    String.duplicate("a", 33),
    "deploy\nroot"
  ]

  test "valid?/1 accepts POSIX-style names (upper case allowed) and rejects the rest" do
    for login <- @valid, do: assert(Login.valid?(login), inspect(login))
    for login <- @invalid, do: refute(Login.valid?(login), inspect(login))
  end

  test "a new or changed authorization login is validated" do
    user = user_fixture()
    host = host_fixture()

    for login <- @invalid do
      attrs = %{user_id: user.id, host_id: host.id, login: login}
      assert {:error, cs} = Authorizations.create_authorization(attrs), inspect(login)
      assert %{login: [_ | _]} = errors_on(cs)
    end

    auth = authorization_fixture(user, host, %{login: "Administrator"})
    assert {:error, cs} = Authorizations.update_authorization(auth, %{login: "-x"})
    assert %{login: [_ | _]} = errors_on(cs)
  end

  test "a stored legacy login stays editable and is copied by a merge" do
    user = user_fixture()
    host = host_fixture()

    legacy =
      Repo.insert!(%Authorization{user_id: user.id, host_id: host.id, login: "CORP\\user"})

    assert {:ok, %{comment: "kept"}} =
             Authorizations.update_authorization(legacy, %{comment: "kept"})

    target = user_fixture()
    assert {:ok, %{copied_authorizations: 1}} = BulkOps.merge_users([user], target)
    assert Authorizations.exists?(target.id, host.id, "CORP\\user")
  end

  test "a grant login is validated" do
    for login <- ["-x", "1234", "user@corp"] do
      cs =
        Grant.create_changeset(%Grant{}, %{ssh_user_id: 1, customer_id: 1, login: login}, %{
          created_by: "t"
        })

      assert %{login: [_ | _]} = errors_on(cs), login
    end

    cs =
      Grant.create_changeset(%Grant{}, %{ssh_user_id: 1, customer_id: 1, login: "deploy"}, %{
        created_by: "t"
      })

    assert cs.valid?
  end
end
