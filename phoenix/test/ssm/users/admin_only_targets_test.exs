defmodule Ssm.Users.AdminOnlyTargetsTest do
  @moduledoc """
  A key that lands in an SSH user inherits that user's grants, options
  included. So a non-admin may not add, move, merge, split or assign a key
  into an SSH user holding a grant with admin-only (permissive) options
  (`Ssm.Authorizations.Options.admin_only/1`): `{:error,
  :admin_only_options}`, audited. Enforced in the scoped context functions;
  admins are unaffected, the scope-less API path is unchanged.
  """

  use Ssm.DataCase, async: true

  import Ssm.Fixtures

  alias Ssm.{Activity, Scope, Users}
  alias Ssm.Users.{BulkOps, KeyAssignment}

  @op [role: "operator", actor: "op@sso"]
  @admin [role: "admin", actor: "admin"]

  setup do
    host = host_fixture()
    wide = user_fixture(%{username: "wide"})
    key_fixture(wide, %{key_base64: "WIDEKEY"})
    authorization_fixture(wide, host, %{login: "deploy", options: "agent-forwarding"})

    plain = user_fixture(%{username: "plain"})
    plain_key = key_fixture(plain, %{key_base64: "PLAINKEY"})
    key_fixture(plain, %{key_base64: "PLAINKEY2"})
    authorization_fixture(plain, host, %{login: "deploy", options: "no-pty"})

    %{host: host, wide: wide, plain: plain, plain_key: plain_key}
  end

  defp key_attrs(user, base64),
    do: %{"user_id" => user.id, "key_type" => "ssh-ed25519", "key_base64" => base64}

  defp assert_refusal_audited(actor) do
    entry = hd(Activity.list())
    assert {entry.action, entry.actor_username} == {"admin_only_refused", actor}
    assert Activity.details(entry)["reason"] =~ "admin-only"
  end

  test "an operator cannot add a key to a user with permissive grants", %{wide: wide} do
    assert {:error, :admin_only_options} =
             Users.create_key(Scope.global(), key_attrs(wide, "NEWKEY"), @op)

    assert_refusal_audited("op@sso")
    assert {:ok, _} = Users.create_key(Scope.global(), key_attrs(wide, "NEWKEY"), @admin)
  end

  test "without a role the scoped write fails closed", %{wide: wide, plain: plain} do
    assert {:error, :admin_only_options} =
             Users.create_key(Scope.global(), key_attrs(wide, "NEWKEY"))

    assert {:ok, _} = Users.create_key(Scope.global(), key_attrs(plain, "OKKEY"))
  end

  test "an operator may add keys to a user with restrictive grants only", %{plain: plain} do
    assert {:ok, _} = Users.create_key(Scope.global(), key_attrs(plain, "NEWKEY"), @op)
  end

  test "an operator cannot move a key into such a user or change its material",
       %{wide: wide, plain_key: key} do
    assert {:error, :admin_only_options} =
             Users.update_key(Scope.global(), key, %{"user_id" => wide.id}, @op)

    [wide_key] = Users.list_keys() |> Enum.filter(&(&1.user_id == wide.id))

    assert {:error, :admin_only_options} =
             Users.update_key(Scope.global(), wide_key, %{"key_base64" => "SWAPPED"}, @op)

    assert {:ok, _} = Users.update_key(Scope.global(), wide_key, %{"name" => "renamed"}, @op)
  end

  test "an operator cannot split or merge a user with permissive grants",
       %{wide: wide, plain: plain, plain_key: key} do
    key_fixture(wide, %{key_base64: "WIDEKEY2"})
    [wide_key | _] = Users.list_keys() |> Enum.filter(&(&1.user_id == wide.id))

    assert {:error, :admin_only_options} =
             BulkOps.split_user(Scope.global(), wide, "wide-2", [wide_key.id], @op)

    # a source with permissive grants would copy them to the target
    assert {:error, :admin_only_options} =
             BulkOps.merge_users(Scope.global(), [wide, plain], plain, @op)

    assert {:error, :admin_only_options} =
             BulkOps.merge_users(Scope.global(), [plain, wide], wide, @op)

    assert {:ok, _} = BulkOps.split_user(Scope.global(), plain, "plain-2", [key.id], @op)
  end

  test "an admin may split and merge such users", %{wide: wide, plain: plain} do
    assert {:ok, _} = BulkOps.merge_users(Scope.global(), [wide, plain], wide, @admin)
  end

  test "an operator cannot assign a diff-page key to such a user", %{host: host, wide: wide} do
    params = %{
      user: wide,
      username: nil,
      key_name: nil,
      parsed: %{key_type: "ssh-ed25519", key_base64: "FOUNDKEY", name: "x"},
      host_id: host.id,
      login: "deploy",
      scope: Scope.global(),
      role: "operator",
      actor: "op@sso"
    }

    assert {:error, {:key, message}} = KeyAssignment.assign(params)
    assert message =~ "admin"
    assert_refusal_audited("op@sso")
    assert {:ok, _} = KeyAssignment.assign(%{params | role: "admin"})
  end

  test "the scope-less API path is unchanged", %{wide: wide} do
    assert {:ok, _} = Users.create_key(key_attrs(wide, "APIKEY"))
  end
end
