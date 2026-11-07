defmodule Ssm.AccountsVerifiedEmailTest do
  # offboarding matches by `verified_email`: set once from the first login
  # with a verified e-mail, never moved by a later claim
  use Ssm.DataCase, async: false

  alias Ssm.Accounts

  @iss "https://idp.example.com"

  defp login(sub, email, verified) do
    {:ok, op} =
      Accounts.upsert_from_oidc(@iss, sub, %{
        name: "Ada",
        email: email,
        email_verified: verified,
        role: "operator",
        customers: []
      })

    op
  end

  test "an unverified login sets no verified e-mail" do
    op = login("s1", "ada@example.com", false)
    assert op.email == "ada@example.com"
    refute op.email_verified
    assert op.verified_email == nil
  end

  test "the first verified e-mail stays, a later claim does not move it" do
    assert login("s2", "ada@example.com", true).verified_email == "ada@example.com"

    later = login("s2", "bob@example.com", true)
    assert later.email == "bob@example.com"
    assert later.verified_email == "ada@example.com"

    assert login("s2", "eve@example.com", false).verified_email == "ada@example.com"
  end

  test "a verified login after unverified ones sets it then" do
    login("s3", "ada@example.com", false)
    assert login("s3", "ada@example.com", true).verified_email == "ada@example.com"
  end
end
