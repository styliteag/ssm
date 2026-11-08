defmodule Ssm.Authorizations.LoginTest do
  @moduledoc """
  The remote login of an authorization or grant must be a POSIX-style user
  name or an SSSD/AD `user@domain` (`Ssm.Authorizations.Login`) when it is
  set or changed. Rows already
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

  @valid ~w(deploy root a _svc Administrator infectopharm.com fail2ban-qa web_dev01 machine$
            user@corp.example jane.doe@ad.corp.example J_Doe@CORP.LOCAL svc-x@a a@b-c.d
            a@1corp.example _x@x9) ++
           [
             String.duplicate("a", 32),
             String.duplicate("a", 64) <> "@corp.example",
             # 128 characters in all: 64 + "@" + 63
             String.duplicate("a", 64) <> "@" <> String.duplicate("b", 59) <> ".com"
           ]

  @invalid [
    "",
    "-oProxyCommand=x",
    "-",
    "1234",
    "0",
    "9user",
    ".hidden",
    "a b",
    "CORP\\user",
    "corp.example\\user@x",
    "@corp.example",
    "user@",
    "user@@corp.example",
    "user@corp@example",
    "1234@corp.example",
    "-x@corp.example",
    ".x@corp.example",
    "machine$@corp.example",
    "user@corp.example$",
    "user@-corp.example",
    "user@corp-.example",
    "user@corp..example",
    "user@.corp",
    "user@corp.",
    "user@corp_x.example",
    "user@corp example",
    "user@corp:22",
    "user@corp/x",
    "user name@corp",
    "user@corp\nroot",
    "user@corp\texample",
    "user@corp\0",
    "user@corp.example\n",
    String.duplicate("a", 33),
    String.duplicate("a", 65) <> "@corp.example",
    # 129 characters in all
    String.duplicate("a", 64) <> "@" <> String.duplicate("b", 60) <> ".com",
    "../etc",
    "a/b",
    "x$y",
    "$",
    "deploy\nroot"
  ]

  test "valid?/1 accepts POSIX-style names and user@domain (upper case allowed), rejects the rest" do
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

  test "a user@domain login (SSSD/AD) is accepted for authorizations and grants" do
    user = user_fixture()
    host = host_fixture()

    assert {:ok, %{login: "jane.doe@ad.corp.example"}} =
             Authorizations.create_authorization(%{
               user_id: user.id,
               host_id: host.id,
               login: "jane.doe@ad.corp.example"
             })

    cs =
      Grant.create_changeset(
        %Grant{},
        %{ssh_user_id: 1, customer_id: 1, login: "svc@corp.example"},
        %{created_by: "t"}
      )

    assert cs.valid?
  end

  test "a grant login is validated" do
    for login <- ["-x", "1234", "CORP\\user", "user@-corp"] do
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
