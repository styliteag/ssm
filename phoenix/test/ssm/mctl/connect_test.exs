defmodule Ssm.Mctl.ConnectTest do
  use Ssm.DataCase, async: false

  alias MctlContract.Tokens
  alias Ssm.Mctl.Connect

  test "create refuses empty scopes and logs nothing" do
    assert {:error, :no_scopes} = Connect.create("admin", [])
    assert Connect.status() == nil
  end

  test "rotate without a token is :not_found" do
    assert {:error, :not_found} = Connect.rotate("admin")
  end

  test "revoke without an active token is :none" do
    assert :none = Connect.revoke("admin")
  end

  test "base_url is the endpoint's public URL" do
    assert Connect.base_url() == SsmWeb.Endpoint.url()
  end

  test "create returns plain token that verifies as mission-control" do
    assert {:ok, plain} = Connect.create("admin", ["read"])
    assert {:ok, %{name: "mission-control"}} = Tokens.Ecto.verify(plain)
  end
end
