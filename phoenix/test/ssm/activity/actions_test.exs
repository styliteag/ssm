defmodule Ssm.Activity.ActionsTest do
  @moduledoc """
  The catalog of activity-log actions. Stored strings are history and the
  activity filters match on them: the list below is a snapshot, a changed or
  dropped string fails here. Every literal action in `lib/` must be listed.
  """

  use ExUnit.Case, async: true

  alias Ssm.Activity.Actions

  @stored ~w(
    create update delete import enable disable split merge bulk_grant
    sync sync_partial sync_failed sync_revocation sync_revocation_partial sync_revocation_failed
    remove_keys remove_keys_failed forget_login forget_login_failed
    grant_create grant_delete grant_add grant_remove grant_move
    admin_only_refused login_locked pin_host_key accept_host_key
    create_rolled_back customer_merge customer_delete group_delete probe_ssh mctl_remove_person
    mctl_auth_failed mctl_auth_locked mctl.connect.create mctl.connect.rotate mctl.connect.revoke
    oidc.login oidc.backchannel_logout oidc.login_refused
  )

  test "the catalog holds exactly the stored strings, each once" do
    assert Enum.sort(Actions.all()) == Enum.sort(@stored)
    assert Actions.all() == Enum.uniq(Actions.all())
  end

  test "names map atoms to the stored strings" do
    assert Actions.name(:create) == "create"
    assert Actions.name(:sync_partial) == "sync_partial"
    assert Actions.name(:oidc_login_refused) == "oidc.login_refused"
    assert Actions.name(:mctl_connect_rotate) == "mctl.connect.rotate"
    assert Actions.known?("grant_move")
    refute Actions.known?("made_up")
    made_up = String.to_atom("made_up")
    assert_raise FunctionClauseError, fn -> Actions.name(made_up) end
  end

  # `action: "x"` and `action: if(…, do: "x", else: "y")`; actions passed to
  # a helper (`audit(…, "x")`, `"customer_" <> action`) are in the snapshot
  @literal ~r/(?:action: |(?:do|else): )"([a-z][a-z_.]*)"(?! <>)/

  test "every literal action in lib/ is in the catalog" do
    literals =
      for path <- Path.wildcard("lib/**/*.ex"),
          line <- path |> File.read!() |> String.split("\n"),
          String.contains?(line, "action: "),
          [_ | groups] <- Regex.scan(@literal, line),
          name <- groups,
          name != "",
          uniq: true,
          do: {name, path}

    assert literals != []
    assert Enum.reject(literals, fn {name, _} -> Actions.known?(name) end) == []
  end
end
