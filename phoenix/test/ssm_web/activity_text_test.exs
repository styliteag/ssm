defmodule SsmWeb.ActivityTextTest do
  use ExUnit.Case, async: true

  alias SsmWeb.ActivityText

  test "known actions read as words, unknown ones lose their separators" do
    assert ActivityText.action("pin_host_key") == "host key pinned"
    assert ActivityText.action("oidc.login") == "signed in (SSO)"
    assert ActivityText.action("some_new.thing") == "some new thing"
    assert ActivityText.action(nil) == ""
  end

  test "every cataloged action has words" do
    for stored <- Ssm.Activity.Actions.all() do
      refute ActivityText.action(stored) =~ "_"
    end
  end
end
