defmodule Ssm.Authorizations.OptionRolesTest do
  @moduledoc """
  Permissive authorized_keys options (`environment`, `cert-authority`,
  `user-rc`, `permitopen`/`permitlisten`, the re-enabling `pty`,
  `port-forwarding`, `agent-forwarding`, `X11-forwarding`, `tunnel`, and
  `no-touch-required`) are admin-only on the web UI paths (the scoped
  context functions). Operators may set restrictive options only. The
  scope-less API path is unchanged.
  """

  use Ssm.DataCase, async: true

  import Ssm.Fixtures

  alias Ssm.Authorizations
  alias Ssm.Authorizations.Options
  alias Ssm.Scope

  @permissive [
    ~s(environment="A=b"),
    "cert-authority",
    "user-rc",
    ~s(permitopen="db:5432"),
    ~s(permitlisten="8080"),
    "pty",
    "port-forwarding",
    "agent-forwarding",
    "X11-forwarding",
    ~s(tunnel="1"),
    "no-touch-required"
  ]

  @restrictive ~s(restrict,no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,) <>
                 ~s(no-user-rc,from="10.0.0.0/8",command="/bin/true",expiry-time="20300101",) <>
                 ~s(verify-required,principals="ops")

  defp attrs(options) do
    %{user_id: user_fixture().id, host_id: host_fixture().id, login: "deploy", options: options}
  end

  describe "Options.admin_only/1" do
    test "names every permissive option, case-insensitively, once" do
      for option <- @permissive do
        assert [_] = Options.admin_only(option), option
      end

      assert Options.admin_only("PTY,no-pty,pty") == ["pty"]
      assert Options.admin_only(@restrictive) == []
      assert Options.admin_only(nil) == []
      assert Options.admin_only("") == []
    end
  end

  describe "create" do
    test "an operator may not set a permissive option" do
      for option <- @permissive do
        assert {:error, changeset} =
                 Authorizations.create_authorization(Scope.global(), attrs(option),
                   role: "operator"
                 )

        assert %{options: [message]} = errors_on(changeset)
        assert message =~ "admin"
      end
    end

    test "an operator may set restrictive options" do
      assert {:ok, auth} =
               Authorizations.create_authorization(Scope.global(), attrs(@restrictive),
                 role: "operator"
               )

      assert auth.options == @restrictive
    end

    test "an admin may set permissive options" do
      assert {:ok, _} =
               Authorizations.create_authorization(Scope.global(), attrs("agent-forwarding"),
                 role: "admin"
               )
    end

    test "without a role a scoped write fails closed" do
      assert {:error, _} = Authorizations.create_authorization(Scope.global(), attrs("pty"))
      assert {:ok, _} = Authorizations.create_authorization(Scope.global(), attrs("no-pty"))
    end

    test "the scope-less API path is unchanged" do
      assert {:ok, _} = Authorizations.create_authorization(attrs("pty"))
    end
  end

  describe "update" do
    setup do
      {:ok, auth} = Authorizations.create_authorization(attrs(~s(environment="A=b")))
      %{auth: auth}
    end

    test "an operator may edit the comment of an admin's grant with permissive options",
         %{auth: auth} do
      assert {:ok, _} =
               Authorizations.update_authorization(Scope.global(), auth, %{comment: "x"},
                 role: "operator"
               )
    end

    test "an operator may not move such a grant or set a permissive option", %{auth: auth} do
      for change <- [%{login: "other"}, %{host_id: host_fixture().id}, %{options: "pty"}] do
        assert {:error, changeset} =
                 Authorizations.update_authorization(Scope.global(), auth, change,
                   role: "operator"
                 )

        assert %{options: [_]} = errors_on(changeset)
      end
    end

    test "an operator may replace permissive options with restrictive ones", %{auth: auth} do
      assert {:ok, %{options: "no-pty"}} =
               Authorizations.update_authorization(Scope.global(), auth, %{options: "no-pty"},
                 role: "operator"
               )
    end
  end

  describe "bulk grant" do
    test "an operator's bulk grant with a permissive option creates nothing" do
      user = user_fixture()
      host = host_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Authorizations.bulk_grant(Scope.global(), [user.id], [host.id], "ops", "pty",
                 role: "operator"
               )

      assert %{options: [_]} = errors_on(changeset)
      refute Authorizations.exists?(user.id, host.id, "ops")
    end

    test "an admin's bulk grant may carry permissive options" do
      user = user_fixture()
      host = host_fixture()

      assert {:ok, %{created: [_]}} =
               Authorizations.bulk_grant(Scope.global(), [user.id], [host.id], "ops", "pty",
                 role: "admin"
               )
    end
  end
end
